import Foundation

@testable import CodexProviderSwitcher

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    var value: String?

    init(value: String? = "test-deepseek-key") {
        self.value = value
    }

    func read(service: String, account: String) throws -> String? {
        value
    }

    func write(_ value: String, service: String, account: String) throws {
        self.value = value
    }

    func delete(service: String, account: String) throws {
        value = nil
    }
}

final class RecordingProcessController: ChatGPTProcessControlling, @unchecked Sendable {
    var running = true
    var stopsImmediately = true
    var waitResult = true
    var launchError: Error?
    var failNextLaunchOnly = false
    private(set) var events: [String] = []
    private(set) var launchEnvironments: [[String: String]] = []

    func isRunning() -> Bool {
        running
    }

    func requestTermination() async throws {
        events.append("terminate")
        if stopsImmediately {
            running = false
        }
    }

    func waitUntilStopped(timeout: Duration) async -> Bool {
        events.append("wait")
        return waitResult && !running
    }

    func launch(environment: [String: String]) throws {
        events.append("launch")
        launchEnvironments.append(environment)
        running = true
        if let launchError, failNextLaunchOnly {
            failNextLaunchOnly = false
            self.launchError = nil
            throw launchError
        }
    }

    func waitUntilRunning(timeout: Duration) async -> Bool {
        events.append("ready")
        return running
    }
}

struct RecordingHTTPProbe: HTTPProbe {
    let status: Int

    func head(_ url: URL, timeout: Duration) async throws -> Int {
        status
    }
}

final class RecordingModelCatalogChecker: DeepSeekModelCatalogChecking, @unchecked Sendable {
    var models: [String]

    init(models: [String]) {
        self.models = models
    }

    func listModels(baseURL: URL, apiKey: String, timeout: Duration) async throws -> [String] {
        models
    }
}

final class RecordingModelResponseTester: DeepSeekModelResponseTesting, @unchecked Sendable {
    let model: String
    private(set) var callCount = 0

    init(model: String) {
        self.model = model
    }

    func sendMinimalTest(baseURL: URL, model: String, apiKey: String, timeout: Duration) async throws -> String {
        callCount += 1
        return self.model
    }
}

final class RecordingSwitchLock: SwitchLocking, @unchecked Sendable {
    var acquireError: Error?
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0

    func acquire() throws {
        acquireCount += 1
        if let acquireError {
            throw acquireError
        }
    }

    func release() {
        releaseCount += 1
    }
}

struct FixedClock: Clock {
    let now: Date
}

final class FailingSnapshotStore: ConfigSnapshotStoring, @unchecked Sendable {
    let base: SnapshotStore
    var failOnReplace = false

    init(base: SnapshotStore) {
        self.base = base
    }

    func capture(configURL: URL, targetMode: ProviderMode, now: Date) throws -> ConfigSnapshot {
        try base.capture(configURL: configURL, targetMode: targetMode, now: now)
    }

    func read(_ snapshot: ConfigSnapshot) throws -> String {
        try base.read(snapshot)
    }

    func atomicallyReplace(configURL: URL, with text: String) throws {
        if failOnReplace {
            throw SnapshotStoreError.replacementFailed("injected failure")
        }
        try base.atomicallyReplace(configURL: configURL, with: text)
    }
}
