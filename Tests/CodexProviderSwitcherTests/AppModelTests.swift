import Foundation
import XCTest

@testable import CodexProviderSwitcher

@MainActor
final class AppModelTests: XCTestCase {
    func testSuccessfulSwitchUpdatesModeStatusBusyAndSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        let snapshotID = "20260808-000000000-deepseek-test"
        let coordinator = RecordingProviderSwitching(
            currentMode: .gpt,
            switchResult: SwitchResult(targetMode: .deepSeek, snapshotID: snapshotID)
        )
        let model = AppModel(
            coordinator: coordinator,
            snapshotsRootURL: directory.appendingPathComponent("snapshots"),
            logsURL: directory.appendingPathComponent("logs")
        )

        await model.switchToDeepSeek()

        XCTAssertEqual(model.currentMode, .deepSeek)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.statusMessage.contains("DeepSeek"))
        XCTAssertEqual(
            model.lastSnapshotURL,
            directory
                .appendingPathComponent("snapshots")
                .appendingPathComponent(snapshotID)
                .appendingPathComponent("config.toml")
        )
        XCTAssertEqual(coordinator.switchCalls, [.deepSeek])
    }

    func testFailedSwitchClearsBusyAndReportsSafeRollbackStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let coordinator = RecordingProviderSwitching(
            currentMode: .gpt,
            switchError: .rolledBack
        )
        let model = AppModel(
            coordinator: coordinator,
            snapshotsRootURL: directory.appendingPathComponent("snapshots"),
            logsURL: directory.appendingPathComponent("logs")
        )

        await model.switchToDeepSeek()

        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.statusMessage.contains("恢复"))
        XCTAssertEqual(model.currentMode, .gpt)
    }

    func testModelGuardStartsPublishesRepairStateAndStops() async throws {
        let directory = try makeTemporaryDirectory()
        let coordinator = RecordingProviderSwitching(currentMode: .deepSeek)
        let modelGuard = RecordingDeepSeekModelGuard()
        let model = AppModel(
            coordinator: coordinator,
            snapshotsRootURL: directory.appendingPathComponent("snapshots"),
            logsURL: directory.appendingPathComponent("logs"),
            modelGuard: modelGuard
        )

        XCTAssertEqual(modelGuard.startCount, 1)
        modelGuard.emit(.repaired(model: "deepseek-v4-flash"))
        await Task.yield()

        XCTAssertEqual(model.modelGuardState, .repaired(model: "deepseek-v4-flash"))
        XCTAssertTrue(model.statusMessage.contains("deepseek-v4-flash"))
        XCTAssertTrue(model.modelGuardSummary.contains("deepseek-v4-flash"))

        model.stopModelGuard()

        XCTAssertEqual(modelGuard.stopCount, 1)
        XCTAssertEqual(model.modelGuardState, .stopped)
    }

    func testCheckOnlyCallsPreflightAndNeverSwitches() async throws {
        let directory = try makeTemporaryDirectory()
        let coordinator = RecordingProviderSwitching(
            currentMode: .gpt,
            preflightReport: EndpointPreflightReport(
                reachable: true,
                responsesDeclared: true,
                messages: ["endpoint reachable"]
            )
        )
        let model = AppModel(
            coordinator: coordinator,
            snapshotsRootURL: directory.appendingPathComponent("snapshots"),
            logsURL: directory.appendingPathComponent("logs")
        )

        await model.runPreflight()

        XCTAssertEqual(coordinator.preflightCalls, 1)
        XCTAssertTrue(coordinator.switchCalls.isEmpty)
        XCTAssertTrue(model.statusMessage.contains("通过"))
        XCTAssertFalse(model.isBusy)
    }

    func testLaunchIntentParserAcceptsWrapperAndFixtureArguments() throws {
        let configuration = try LaunchIntentParser.parse(arguments: [
            "CodexProviderSwitcher",
            "--mode=deepseek",
            "--codex-home",
            "/tmp/test-codex-home",
            "--chatgpt-app",
            "/tmp/ChatGPT.app"
        ])

        XCTAssertEqual(configuration.intent, .switchTo(.deepSeek))
        XCTAssertEqual(configuration.codexHomeOverride?.path, "/tmp/test-codex-home")
        XCTAssertEqual(configuration.chatGPTApplicationOverride?.path, "/tmp/ChatGPT.app")
    }

    func testCheckIntentDoesNotConflictWithInteractiveDefault() throws {
        XCTAssertEqual(
            try LaunchIntentParser.parse(arguments: ["CodexProviderSwitcher"]).intent,
            .interactive
        )
        XCTAssertEqual(
            try LaunchIntentParser.parse(arguments: ["--check"]).intent,
            .checkOnly
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-switcher-app-model-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class RecordingProviderSwitching: ProviderSwitching, @unchecked Sendable {
    var currentModeValue: ProviderMode
    var switchResult: SwitchResult?
    var switchError: SwitchError?
    var preflightReport: EndpointPreflightReport
    private(set) var switchCalls: [ProviderMode] = []
    private(set) var preflightCalls = 0

    init(
        currentMode: ProviderMode,
        switchResult: SwitchResult? = nil,
        switchError: SwitchError? = nil,
        preflightReport: EndpointPreflightReport = EndpointPreflightReport(
            reachable: false,
            responsesDeclared: false,
            messages: ["endpoint unavailable"]
        )
    ) {
        self.currentModeValue = currentMode
        self.switchResult = switchResult
        self.switchError = switchError
        self.preflightReport = preflightReport
    }

    func currentMode() throws -> ProviderMode {
        currentModeValue
    }

    func currentStatus() throws -> ProviderStatus {
        switchResult?.status ?? .unverified(mode: currentModeValue)
    }

    func switchTo(_ targetMode: ProviderMode) async throws -> SwitchResult {
        switchCalls.append(targetMode)
        if let switchError {
            throw switchError
        }
        return switchResult ?? SwitchResult(targetMode: targetMode, snapshotID: nil)
    }

    func verifyCurrentProvider() async throws -> ProviderStatus {
        switchResult?.status ?? .unverified(mode: currentModeValue)
    }

    func checkPreflight() async throws -> EndpointPreflightReport {
        preflightCalls += 1
        return preflightReport
    }
}

@MainActor
final class RecordingDeepSeekModelGuard: DeepSeekModelGuarding {
    private(set) var state: DeepSeekModelGuardState = .stopped
    var onStateChange: ((DeepSeekModelGuardState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
        state = .monitoring
        onStateChange?(state)
    }

    func stop() {
        stopCount += 1
        state = .stopped
        onStateChange?(state)
    }

    func emit(_ state: DeepSeekModelGuardState) {
        self.state = state
        onStateChange?(state)
    }
}
