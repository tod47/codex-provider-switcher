import Foundation

protocol ConfigSnapshotStoring: AnyObject {
    func capture(configURL: URL, targetMode: ProviderMode, now: Date) throws -> ConfigSnapshot
    func read(_ snapshot: ConfigSnapshot) throws -> String
    func atomicallyReplace(configURL: URL, with text: String) throws
}

protocol SwitchLocking: AnyObject {
    func acquire() throws
    func release()
}

enum SwitchLockError: Error, Equatable {
    case alreadyHeld
    case failed
}

final class FileSwitchLock: SwitchLocking, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private var held = false

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func acquire() throws {
        guard !held else {
            throw SwitchLockError.alreadyHeld
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            held = true
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                throw SwitchLockError.alreadyHeld
            }
            throw SwitchLockError.failed
        }
    }

    func release() {
        guard held else {
            return
        }
        try? fileManager.removeItem(at: url)
        held = false
    }

    deinit {
        release()
    }
}

struct SwitchResult: Equatable, Sendable {
    let targetMode: ProviderMode
    let snapshotID: String?
}

enum SwitchError: Error, Equatable {
    case alreadyRunning
    case lockFailed
    case unsupportedTarget
    case unknownCurrentMode
    case preflightFailed([String])
    case secretStoreFailed
    case configurationReadFailed
    case configurationTransformFailed
    case snapshotFailed
    case manifestFailed
    case chatGPTTerminationFailed
    case chatGPTDidNotStop
    case configurationWriteFailed
    case launchFailed
    case rolledBack
}

final class SwitchTransactionCoordinator: @unchecked Sendable, ProviderSwitching {
    private let settings: SwitchSettings
    private let transformer: CodexConfigTransformer
    private let snapshotStore: any ConfigSnapshotStoring
    private let manifestStore: ManifestStore
    private let secretStore: any SecretStore
    private let preflight: EndpointPreflight
    private let processController: any ChatGPTProcessControlling
    private let lock: any SwitchLocking
    private let clock: any Clock

    init(
        settings: SwitchSettings,
        transformer: CodexConfigTransformer,
        snapshotStore: any ConfigSnapshotStoring,
        manifestStore: ManifestStore,
        secretStore: any SecretStore,
        preflight: EndpointPreflight,
        processController: any ChatGPTProcessControlling,
        lock: any SwitchLocking,
        clock: any Clock = SystemClock()
    ) {
        self.settings = settings
        self.transformer = transformer
        self.snapshotStore = snapshotStore
        self.manifestStore = manifestStore
        self.secretStore = secretStore
        self.preflight = preflight
        self.processController = processController
        self.lock = lock
        self.clock = clock
    }

    func currentMode() throws -> ProviderMode {
        let config = try readConfig()
        return transformer.detectMode(in: config, settings: settings.deepSeek)
    }

    func checkPreflight() async throws -> EndpointPreflightReport {
        let secret = try requiredDeepSeekSecret()
        return await preflight.check(
            settings: settings.deepSeek,
            secretAvailable: secret != nil
        )
    }

    func switchTo(_ targetMode: ProviderMode) async throws -> SwitchResult {
        do {
            try lock.acquire()
        } catch let error as SwitchLockError {
            if error == .alreadyHeld {
                throw SwitchError.alreadyRunning
            }
            throw SwitchError.lockFailed
        } catch {
            throw SwitchError.lockFailed
        }
        defer { lock.release() }

        guard targetMode == .gpt || targetMode == .deepSeek else {
            throw SwitchError.unsupportedTarget
        }

        let originalConfig = try readConfig()
        let currentMode = transformer.detectMode(in: originalConfig, settings: settings.deepSeek)
        guard currentMode != .unknown else {
            throw SwitchError.unknownCurrentMode
        }
        if currentMode == targetMode {
            return SwitchResult(targetMode: targetMode, snapshotID: nil)
        }

        var manifest = try loadManifest()
        var deepSeekSecret: String?

        if targetMode == .deepSeek {
            deepSeekSecret = try requiredDeepSeekSecret()
            let report = await preflight.check(
                settings: settings.deepSeek,
                secretAvailable: deepSeekSecret != nil
            )
            guard report.reachable, report.responsesDeclared else {
                throw SwitchError.preflightFailed(report.messages)
            }
        } else if currentMode == .deepSeek {
            // GPT can still be restored if the credential has since been removed.
            // The optional value is only needed if a later rollback must relaunch DeepSeek.
            deepSeekSecret = try? secretStore.read(
                service: settings.keychainService,
                account: settings.keychainAccount
            )
        }

        let targetConfig = try makeTargetConfig(
            targetMode: targetMode,
            currentConfig: originalConfig,
            manifest: manifest
        )
        let targetEnvironment = environment(for: targetMode, deepSeekSecret: deepSeekSecret)
        let previousEnvironment = environment(for: currentMode, deepSeekSecret: deepSeekSecret)
        let transactionID = UUID().uuidString.lowercased()

        manifest.activeMode = currentMode
        manifest.transactionID = transactionID
        manifest.transactionPhase = "preparing"
        try saveManifest(manifest)

        var rollbackSnapshot: ConfigSnapshot?
        var processStopped = false
        var configReplaced = false

        do {
            do {
                rollbackSnapshot = try snapshotStore.capture(
                    configURL: settings.codexConfigURL,
                    targetMode: currentMode,
                    now: clock.now
                )
            } catch {
                throw SwitchError.snapshotFailed
            }

            if currentMode == .gpt, let rollbackSnapshot {
                manifest.lastGPTSnapshot = rollbackSnapshot
            }
            manifest.transactionPhase = "snapshotted"
            try saveManifest(manifest)

            manifest.transactionPhase = "stopping"
            try saveManifest(manifest)
            if processController.isRunning() {
                do {
                    try await processController.requestTermination()
                } catch {
                    throw SwitchError.chatGPTTerminationFailed
                }
                guard await processController.waitUntilStopped(
                    timeout: .seconds(settings.quitTimeoutSeconds)
                ) else {
                    throw SwitchError.chatGPTDidNotStop
                }
            }
            processStopped = true

            manifest.transactionPhase = "writing"
            try saveManifest(manifest)
            do {
                try snapshotStore.atomicallyReplace(
                    configURL: settings.codexConfigURL,
                    with: targetConfig
                )
            } catch {
                throw SwitchError.configurationWriteFailed
            }
            configReplaced = true

            manifest.transactionPhase = "launching"
            try saveManifest(manifest)
            do {
                try processController.launch(environment: targetEnvironment)
            } catch {
                throw SwitchError.launchFailed
            }

            manifest.activeMode = targetMode
            manifest.transactionPhase = "completed"
            if targetMode == .gpt {
                manifest.lastGPTSnapshot = nil
            }
            try saveManifest(manifest)

            return SwitchResult(
                targetMode: targetMode,
                snapshotID: rollbackSnapshot?.id
            )
        } catch let error as SwitchError {
            guard processStopped || configReplaced else {
                throw error
            }
            throw await rollback(
                transactionID: transactionID,
                manifest: manifest,
                previousMode: currentMode,
                originalConfig: originalConfig,
                rollbackSnapshot: rollbackSnapshot,
                configReplaced: configReplaced,
                processStopped: processStopped,
                previousEnvironment: previousEnvironment
            )
        } catch {
            guard processStopped || configReplaced else {
                throw SwitchError.manifestFailed
            }
            throw await rollback(
                transactionID: transactionID,
                manifest: manifest,
                previousMode: currentMode,
                originalConfig: originalConfig,
                rollbackSnapshot: rollbackSnapshot,
                configReplaced: configReplaced,
                processStopped: processStopped,
                previousEnvironment: previousEnvironment
            )
        }
    }

    private func readConfig() throws -> String {
        do {
            return try String(contentsOf: settings.codexConfigURL, encoding: .utf8)
        } catch {
            throw SwitchError.configurationReadFailed
        }
    }

    private func loadManifest() throws -> SwitchManifest {
        do {
            return try manifestStore.load()
        } catch {
            throw SwitchError.manifestFailed
        }
    }

    private func saveManifest(_ manifest: SwitchManifest) throws {
        do {
            try manifestStore.save(manifest)
        } catch {
            throw SwitchError.manifestFailed
        }
    }

    private func requiredDeepSeekSecret() throws -> String? {
        let value: String?
        do {
            value = try secretStore.read(
                service: settings.keychainService,
                account: settings.keychainAccount
            )
        } catch {
            throw SwitchError.secretStoreFailed
        }

        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func makeTargetConfig(
        targetMode: ProviderMode,
        currentConfig: String,
        manifest: SwitchManifest
    ) throws -> String {
        switch targetMode {
        case .deepSeek:
            do {
                return try transformer.makeDeepSeekConfig(
                    from: currentConfig,
                    settings: settings.deepSeek
                )
            } catch {
                throw SwitchError.configurationTransformFailed
            }
        case .gpt:
            guard let snapshot = manifest.lastGPTSnapshot else {
                throw SwitchError.snapshotFailed
            }
            do {
                return try snapshotStore.read(snapshot)
            } catch {
                throw SwitchError.snapshotFailed
            }
        case .unknown:
            throw SwitchError.unsupportedTarget
        }
    }

    private func environment(
        for mode: ProviderMode,
        deepSeekSecret: String?
    ) -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        result.removeValue(forKey: settings.deepSeek.environmentKey)
        if mode == .deepSeek, let deepSeekSecret {
            result[settings.deepSeek.environmentKey] = deepSeekSecret
        }
        return result
    }

    private func rollback(
        transactionID: String,
        manifest: SwitchManifest,
        previousMode: ProviderMode,
        originalConfig: String,
        rollbackSnapshot: ConfigSnapshot?,
        configReplaced: Bool,
        processStopped: Bool,
        previousEnvironment: [String: String]
    ) async -> SwitchError {
        if configReplaced {
            try? snapshotStore.atomicallyReplace(
                configURL: settings.codexConfigURL,
                with: originalConfig
            )
        }

        if processStopped {
            if processController.isRunning() {
                try? await processController.requestTermination()
                _ = await processController.waitUntilStopped(
                    timeout: .seconds(settings.quitTimeoutSeconds)
                )
            }
            try? processController.launch(environment: previousEnvironment)
        }

        var rollbackManifest = manifest
        rollbackManifest.activeMode = previousMode
        rollbackManifest.transactionID = transactionID
        rollbackManifest.transactionPhase = "rolledBack"
        if previousMode == .gpt, let rollbackSnapshot {
            rollbackManifest.lastGPTSnapshot = rollbackSnapshot
        }
        try? manifestStore.save(rollbackManifest)
        return .rolledBack
    }
}
