import Darwin
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
    private var fileDescriptor: Int32 = -1

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func acquire() throws {
        guard fileDescriptor == -1 else {
            throw SwitchLockError.alreadyHeld
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw SwitchLockError.failed
        }

        let descriptor = open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw SwitchLockError.failed
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorCode = errno
            close(descriptor)
            if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
                throw SwitchLockError.alreadyHeld
            }
            throw SwitchLockError.failed
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw SwitchLockError.failed
        }

        fileDescriptor = descriptor
    }

    func release() {
        guard fileDescriptor >= 0 else {
            return
        }
        let descriptor = fileDescriptor
        fileDescriptor = -1
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit {
        release()
    }
}

struct SwitchResult: Equatable, Sendable {
    let targetMode: ProviderMode
    let snapshotID: String?
    let status: ProviderStatus

    init(
        targetMode: ProviderMode,
        snapshotID: String?,
        status: ProviderStatus? = nil
    ) {
        self.targetMode = targetMode
        self.snapshotID = snapshotID
        self.status = status ?? .unverified(mode: targetMode)
    }
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
    case chatGPTDidNotStart
    case configurationVerificationFailed
    case providerVerificationFailed([String])
    case rolledBack
}

final class SwitchTransactionCoordinator: @unchecked Sendable, ProviderSwitching {
    private let settings: SwitchSettings
    private let transformer: CodexConfigTransformer
    private let snapshotStore: any ConfigSnapshotStoring
    private let manifestStore: ManifestStore
    private let secretStore: any SecretStore
    private let preflight: EndpointPreflight
    private let modelCatalogChecker: any DeepSeekModelCatalogChecking
    private let modelResponseTester: any DeepSeekModelResponseTesting
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
        modelCatalogChecker: any DeepSeekModelCatalogChecking = URLSessionDeepSeekModelCatalogChecker(),
        modelResponseTester: any DeepSeekModelResponseTesting = URLSessionDeepSeekModelResponseTester(),
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
        self.modelCatalogChecker = modelCatalogChecker
        self.modelResponseTester = modelResponseTester
        self.processController = processController
        self.lock = lock
        self.clock = clock
    }

    func currentMode() throws -> ProviderMode {
        let config = try readConfig()
        return transformer.detectMode(in: config, settings: settings.deepSeek)
    }

    func currentStatus() throws -> ProviderStatus {
        let config = try readConfig()
        guard let configuration = transformer.configuration(in: config, settings: settings.deepSeek) else {
            throw SwitchError.configurationReadFailed
        }

        let manifest = try loadManifest()
        let processRunning = processController.isRunning()
        let persistedVerification: ProviderVerification?
        if let candidate = manifest.lastVerification,
           candidate.verifiedModel == configuration.model,
           candidate.verifiedEndpoint == configuration.endpoint {
            persistedVerification = candidate
        } else {
            persistedVerification = nil
        }
        let verification = persistedVerification ?? {
            guard configuration.mode == .gpt, processRunning else {
                return nil
            }
            return ProviderVerification(
                state: .configurationAndProcessVerified,
                verifiedModel: configuration.model,
                verifiedEndpoint: configuration.endpoint,
                messages: [
                    "GPT 配置已加载",
                    "Codex app-server 已运行"
                ]
            )
        }()

        return ProviderStatus(
            mode: configuration.mode,
            configuredModel: configuration.model,
            endpoint: configuration.endpoint,
            processRunning: processRunning,
            verification: verification
        )
    }

    func verifyCurrentProvider() async throws -> ProviderStatus {
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

        let current = try currentStatus()
        guard current.mode == .deepSeek else {
            return current
        }
        guard let secret = try requiredDeepSeekSecret() else {
            throw SwitchError.providerVerificationFailed(["DeepSeek API Key is missing"])
        }

        do {
            let actualModel = try await modelResponseTester.sendMinimalTest(
                baseURL: URL(string: current.endpoint ?? "") ?? settings.deepSeek.baseURL,
                model: current.configuredModel ?? settings.deepSeek.model,
                apiKey: secret,
                timeout: .seconds(15)
            )
            let verification = ProviderVerification(
                state: .actualResponseVerified,
                verifiedModel: current.configuredModel,
                verifiedEndpoint: current.endpoint,
                actualResponseModel: actualModel,
                messages: [
                    "DeepSeek endpoint 已返回实际响应",
                    "实际响应模型：\(actualModel)"
                ]
            )
            var manifest = try loadManifest()
            manifest.lastVerification = verification
            try saveManifest(manifest)
            return ProviderStatus(
                mode: current.mode,
                configuredModel: current.configuredModel,
                endpoint: current.endpoint,
                processRunning: current.processRunning,
                verification: verification
            )
        } catch let error as SwitchError {
            throw error
        } catch let error as DeepSeekResponseTestError {
            throw SwitchError.providerVerificationFailed([
                responseTestMessage(for: error)
            ])
        } catch {
            throw SwitchError.providerVerificationFailed([
                "实际 DeepSeek 请求失败"
            ])
        }
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
            return SwitchResult(
                targetMode: targetMode,
                snapshotID: nil,
                status: try currentStatus()
            )
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

            guard await processController.waitUntilRunning(
                timeout: .seconds(settings.launchTimeoutSeconds)
            ) else {
                throw SwitchError.chatGPTDidNotStart
            }

            let status = try await verifyActiveTarget(
                targetMode: targetMode,
                deepSeekSecret: deepSeekSecret
            )

            manifest.activeMode = targetMode
            manifest.transactionPhase = "completed"
            manifest.lastVerification = status.verification
            if targetMode == .gpt {
                manifest.lastGPTSnapshot = nil
            }
            try saveManifest(manifest)

            return SwitchResult(
                targetMode: targetMode,
                snapshotID: rollbackSnapshot?.id,
                status: status
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

    private func verifyActiveTarget(
        targetMode: ProviderMode,
        deepSeekSecret: String?
    ) async throws -> ProviderStatus {
        guard processController.isRunning() else {
            throw SwitchError.chatGPTDidNotStart
        }

        let config = try readConfig()
        guard let configuration = transformer.configuration(in: config, settings: settings.deepSeek),
              configuration.mode == targetMode
        else {
            throw SwitchError.configurationVerificationFailed
        }

        switch targetMode {
        case .gpt:
            let verification = ProviderVerification(
                state: .configurationAndProcessVerified,
                verifiedModel: configuration.model,
                verifiedEndpoint: configuration.endpoint,
                messages: [
                    "GPT 配置已恢复",
                    "Codex app-server 已启动"
                ]
            )
            return ProviderStatus(
                mode: targetMode,
                configuredModel: configuration.model,
                endpoint: configuration.endpoint,
                processRunning: true,
                verification: verification
            )
        case .deepSeek:
            guard let deepSeekSecret else {
                throw SwitchError.providerVerificationFailed(["DeepSeek API Key is missing"])
            }

            do {
                let models = try await modelCatalogChecker.listModels(
                    baseURL: URL(string: configuration.endpoint) ?? settings.deepSeek.baseURL,
                    apiKey: deepSeekSecret,
                    timeout: .seconds(5)
                )
                guard models.contains(settings.deepSeek.model) else {
                    throw SwitchError.providerVerificationFailed([
                        "DeepSeek 模型目录中没有 \(settings.deepSeek.model)"
                    ])
                }

                let verification = ProviderVerification(
                    state: .modelAvailable,
                    verifiedModel: settings.deepSeek.model,
                    verifiedEndpoint: configuration.endpoint,
                    messages: [
                        "DeepSeek endpoint 已连接",
                        "模型目录已确认 \(settings.deepSeek.model) 可用"
                    ]
                )
                return ProviderStatus(
                    mode: targetMode,
                    configuredModel: configuration.model,
                    endpoint: configuration.endpoint,
                    processRunning: true,
                    verification: verification
                )
            } catch let error as SwitchError {
                throw error
            } catch let error as DeepSeekModelCatalogError {
                throw SwitchError.providerVerificationFailed([
                    modelCatalogMessage(for: error)
                ])
            } catch {
                throw SwitchError.providerVerificationFailed([
                    "无法读取 DeepSeek 模型目录"
                ])
            }
        case .unknown:
            throw SwitchError.configurationVerificationFailed
        }
    }

    private func modelCatalogMessage(for error: DeepSeekModelCatalogError) -> String {
        switch error {
        case .nonHTTPResponse:
            return "DeepSeek 模型目录返回了非 HTTP 响应"
        case let .unexpectedStatus(status):
            return "DeepSeek 模型目录返回 HTTP \(status)"
        case .invalidPayload:
            return "DeepSeek 模型目录响应格式无法识别"
        }
    }

    private func responseTestMessage(for error: DeepSeekResponseTestError) -> String {
        switch error {
        case .nonHTTPResponse:
            return "DeepSeek 实际测试返回了非 HTTP 响应"
        case let .unexpectedStatus(status):
            return "DeepSeek 实际测试返回 HTTP \(status)"
        case .invalidPayload:
            return "DeepSeek 实际测试响应中没有可识别的 model 字段"
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
            _ = await processController.waitUntilRunning(
                timeout: .seconds(settings.launchTimeoutSeconds)
            )
        }

        var rollbackManifest = manifest
        rollbackManifest.activeMode = previousMode
        rollbackManifest.transactionID = transactionID
        rollbackManifest.transactionPhase = "rolledBack"
        rollbackManifest.lastVerification = manifest.lastVerification
        if previousMode == .gpt, let rollbackSnapshot {
            rollbackManifest.lastGPTSnapshot = rollbackSnapshot
        }
        try? manifestStore.save(rollbackManifest)
        return .rolledBack
    }
}
