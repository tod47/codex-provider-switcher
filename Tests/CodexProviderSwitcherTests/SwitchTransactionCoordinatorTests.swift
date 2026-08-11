import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class SwitchTransactionCoordinatorTests: XCTestCase {
    private let gptConfig = """
    model_provider = "custom"
    model = "gpt-5.6-luna"

    [model_providers.custom]
    name = "OpenAI"
    base_url = "https://chatgpt.com/backend-api/codex"
    wire_api = "responses"
    requires_openai_auth = true
    supports_websockets = false
    """

    func testDeepSeekSwitchSnapshotsQuitsTransformsLaunchesAndUpdatesManifest() async throws {
        let context = try makeContext()
        let result = try await context.coordinator.switchTo(.deepSeek)

        XCTAssertEqual(result.targetMode, .deepSeek)
        XCTAssertNotNil(result.snapshotID)
        XCTAssertEqual(result.status.mode, .deepSeek)
        XCTAssertEqual(result.status.configuredModel, "deepseek-v4-flash")
        XCTAssertEqual(result.status.verification?.state, .modelAvailable)
        XCTAssertEqual(result.status.verification?.verifiedModel, "deepseek-v4-flash")
        XCTAssertEqual(context.process.events, ["terminate", "wait", "launch", "ready"])
        XCTAssertTrue(try String(contentsOf: context.configURL).contains("deepseek-v4-flash"))
        XCTAssertEqual(context.process.launchEnvironments.last?["DEEPSEEK_API_KEY"], "test-deepseek-key")
        XCTAssertEqual(try context.manifestStore.load().activeMode, .deepSeek)
        XCTAssertEqual(try Data(contentsOf: context.stateURL), Data("history sentinel".utf8))
    }

    func testGPTSwitchRestoresTheLastGPTSnapshot() async throws {
        let context = try makeContext()

        _ = try await context.coordinator.switchTo(.deepSeek)
        let result = try await context.coordinator.switchTo(.gpt)

        XCTAssertEqual(try String(contentsOf: context.configURL), gptConfig)
        XCTAssertEqual(try context.manifestStore.load().activeMode, .gpt)
        XCTAssertEqual(result.status.mode, .gpt)
        XCTAssertEqual(result.status.configuredModel, "gpt-5.6-luna")
        XCTAssertEqual(result.status.verification?.state, .configurationAndProcessVerified)
        XCTAssertNil(context.process.launchEnvironments.last?["DEEPSEEK_API_KEY"])
    }

    func testGPTSwitchRestoresSnapshotAfterDeepSeekModelWasChangedByChatGPT() async throws {
        let context = try makeContext()

        _ = try await context.coordinator.switchTo(.deepSeek)
        let editedConfig = try String(contentsOf: context.configURL)
            .replacingOccurrences(
                of: "model = \"deepseek-v4-flash\"",
                with: "model = \"gpt-5.6-terra\""
            )
        try editedConfig.write(to: context.configURL, atomically: true, encoding: .utf8)

        let result = try await context.coordinator.switchTo(.gpt)

        XCTAssertEqual(try String(contentsOf: context.configURL), gptConfig)
        XCTAssertEqual(result.status.mode, .gpt)
        XCTAssertEqual(result.status.configuredModel, "gpt-5.6-luna")
        XCTAssertEqual(try context.manifestStore.load().activeMode, .gpt)
    }

    func testDeepSeekModelVerificationFailureRollsBackToGPT() async throws {
        let context = try makeContext()
        context.modelCatalogChecker.models = []

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected provider verification failure")
        } catch let error as SwitchError {
            guard case .rolledBack = error else {
                return XCTFail("expected rollback error, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: context.configURL), gptConfig)
        XCTAssertEqual(try context.manifestStore.load().activeMode, .gpt)
        XCTAssertEqual(
            context.process.events,
            ["terminate", "wait", "launch", "ready", "terminate", "wait", "launch", "ready"]
        )
    }

    func testExplicitDeepSeekResponseVerificationRecordsTheActualModel() async throws {
        let context = try makeContext()
        _ = try await context.coordinator.switchTo(.deepSeek)

        let status = try await context.coordinator.verifyCurrentProvider()

        XCTAssertEqual(status.mode, .deepSeek)
        XCTAssertEqual(status.verification?.state, .actualResponseVerified)
        XCTAssertEqual(status.verification?.actualResponseModel, "deepseek-v4-flash")
        XCTAssertEqual(try context.manifestStore.load().lastVerification?.actualResponseModel, "deepseek-v4-flash")
        XCTAssertEqual(context.modelResponseTester.callCount, 1)
    }

    func testRepairDeepSeekModelIfNeededRestoresWrongModelWithoutTouchingHistory() async throws {
        let context = try makeContext()
        _ = try await context.coordinator.switchTo(.deepSeek)
        let corrupted = try String(contentsOf: context.configURL)
            .replacingOccurrences(
                of: "model = \"deepseek-v4-flash\"",
                with: "model = \"gpt-5.6-terra\""
            )
        try corrupted.write(to: context.configURL, atomically: true, encoding: .utf8)

        let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

        XCTAssertEqual(result, .repaired(model: "deepseek-v4-flash"))
        XCTAssertTrue(try String(contentsOf: context.configURL).contains(
            "model = \"deepseek-v4-flash\""
        ))
        XCTAssertEqual(
            try Data(contentsOf: context.stateURL),
            Data("history sentinel".utf8)
        )
    }

    func testRepairDeepSeekModelIfNeededNeverChangesGPTConfiguration() async throws {
        let context = try makeContext()
        let original = try Data(contentsOf: context.configURL)

        let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

        XCTAssertEqual(result, .ignored)
        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
    }

    func testRepairDeepSeekModelIfNeededIgnoresLockContention() async throws {
        let context = try makeContext()
        context.lock.acquireError = SwitchLockError.alreadyHeld

        let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

        XCTAssertEqual(result, .ignored)
        XCTAssertEqual(context.lock.acquireCount, 1)
        XCTAssertEqual(context.lock.releaseCount, 0)
    }

    func testUnknownCurrentModeStopsBeforeWriting() async throws {
        let context = try makeContext(config: "model_provider = \"custom\"\n")
        let original = try Data(contentsOf: context.configURL)

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected unknown current mode")
        } catch let error as SwitchError {
            XCTAssertEqual(error, .unknownCurrentMode)
        }

        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        XCTAssertTrue(context.process.events.isEmpty)
    }

    func testChatGPTTimeoutLeavesConfigAndHistorySentinelUnchanged() async throws {
        let context = try makeContext()
        context.process.stopsImmediately = false
        context.process.waitResult = false
        let original = try Data(contentsOf: context.configURL)

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected ChatGPT timeout")
        } catch let error as SwitchError {
            XCTAssertEqual(error, .chatGPTDidNotStop)
        }

        XCTAssertEqual(try Data(contentsOf: context.configURL), original)
        XCTAssertEqual(try Data(contentsOf: context.stateURL), Data("history sentinel".utf8))
        XCTAssertFalse(context.process.events.contains("launch"))
    }

    func testConfigWriteFailureRestartsGPTFromSnapshot() async throws {
        let context = try makeContext()
        context.failingSnapshotStore.failOnReplace = true

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected configuration write failure")
        } catch let error as SwitchError {
            guard case .rolledBack = error else {
                return XCTFail("expected rollback error, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: context.configURL), gptConfig)
        XCTAssertEqual(context.process.launchEnvironments.count, 1)
        XCTAssertNil(context.process.launchEnvironments[0]["DEEPSEEK_API_KEY"])
    }

    func testLaunchFailureRestoresGPTAndRecordsRollback() async throws {
        let context = try makeContext()
        context.process.launchError = ChatGPTProcessError.launchFailed("injected")
        context.process.failNextLaunchOnly = true

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected launch failure")
        } catch let error as SwitchError {
            guard case .rolledBack = error else {
                return XCTFail("expected rollback error, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: context.configURL), gptConfig)
        XCTAssertEqual(try context.manifestStore.load().transactionPhase, "rolledBack")
        XCTAssertEqual(context.process.launchEnvironments.count, 2)
        XCTAssertNil(context.process.launchEnvironments.last?["DEEPSEEK_API_KEY"])
    }

    func testConcurrentSwitchIsRejectedByTheLock() async throws {
        let context = try makeContext()
        context.lock.acquireError = SwitchLockError.alreadyHeld

        do {
            _ = try await context.coordinator.switchTo(.deepSeek)
            XCTFail("expected lock failure")
        } catch let error as SwitchError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        XCTAssertEqual(context.lock.acquireCount, 1)
        XCTAssertEqual(context.lock.releaseCount, 0)
    }

    func testSecretNeverAppearsInArgumentsOrDiagnosticText() async throws {
        let context = try makeContext()
        _ = try await context.coordinator.switchTo(.deepSeek)

        XCTAssertFalse(context.process.events.contains("test-deepseek-key"))
        XCTAssertFalse(context.process.launchEnvironments.isEmpty)
    }

    private func makeContext(config: String? = nil) throws -> TestContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-switcher-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let codexHome = directory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let configURL = codexHome.appendingPathComponent("config.toml")
        try Data((config ?? gptConfig).utf8).write(to: configURL)
        let stateURL = codexHome.appendingPathComponent("state_5.sqlite")
        try Data("history sentinel".utf8).write(to: stateURL)

        let deepSeek = try DeepSeekSettings(
            model: "deepseek-v4-flash",
            baseURL: URL(string: "http://127.0.0.1:4000/v1")!
        )
        let settings = try SwitchSettings(
            codexHome: codexHome,
            chatGPTApplicationURL: directory.appendingPathComponent("ChatGPT.app"),
            deepSeek: deepSeek,
            keychainAccount: "test-user",
            quitTimeoutSeconds: 1,
            launchTimeoutSeconds: 1
        )
        let process = RecordingProcessController()
        let lock = RecordingSwitchLock()
        let secretStore = InMemorySecretStore()
        let baseSnapshotStore = SnapshotStore(rootURL: directory.appendingPathComponent("snapshots"))
        let failingSnapshotStore = FailingSnapshotStore(base: baseSnapshotStore)
        let manifestStore = ManifestStore(url: directory.appendingPathComponent("manifest.json"))
        let modelCatalogChecker = RecordingModelCatalogChecker(models: ["deepseek-v4-flash"])
        let modelResponseTester = RecordingModelResponseTester(model: "deepseek-v4-flash")
        let coordinator = SwitchTransactionCoordinator(
            settings: settings,
            transformer: CodexConfigTransformer(),
            snapshotStore: failingSnapshotStore,
            manifestStore: manifestStore,
            secretStore: secretStore,
            preflight: EndpointPreflight(probe: RecordingHTTPProbe(status: 200)),
            modelCatalogChecker: modelCatalogChecker,
            modelResponseTester: modelResponseTester,
            processController: process,
            lock: lock,
            clock: FixedClock(now: Date(timeIntervalSince1970: 1_754_678_400))
        )

        return TestContext(
            coordinator: coordinator,
            configURL: configURL,
            stateURL: stateURL,
            process: process,
            lock: lock,
            manifestStore: manifestStore,
            failingSnapshotStore: failingSnapshotStore,
            modelCatalogChecker: modelCatalogChecker,
            modelResponseTester: modelResponseTester,
            directory: directory
        )
    }
}

private struct TestContext {
    let coordinator: SwitchTransactionCoordinator
    let configURL: URL
    let stateURL: URL
    let process: RecordingProcessController
    let lock: RecordingSwitchLock
    let manifestStore: ManifestStore
    let failingSnapshotStore: FailingSnapshotStore
    let modelCatalogChecker: RecordingModelCatalogChecker
    let modelResponseTester: RecordingModelResponseTester
    let directory: URL
}
