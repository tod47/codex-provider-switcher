import XCTest

@testable import CodexProviderSwitcher

@MainActor
final class ConfigFileMonitorTests: XCTestCase {
    func testGuardStartPerformsInitialRepairAndPublishesState() async throws {
        let watcher = RecordingConfigDirectoryWatcher()
        let repairer = RecordingDeepSeekModelRepairer()
        repairer.result = .success(.repaired(model: "deepseek-v4-flash"))
        var states: [DeepSeekModelGuardState] = []
        let guarder = DeepSeekModelGuard(
            watcher: watcher,
            repairer: repairer,
            debounceNanoseconds: 1_000_000,
            onStateChange: { states.append($0) }
        )

        guarder.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(repairer.callCount, 1)
        XCTAssertTrue(states.contains(.monitoring))
        XCTAssertTrue(states.contains(.repaired(model: "deepseek-v4-flash")))
        XCTAssertEqual(guarder.state, .repaired(model: "deepseek-v4-flash"))
    }

    func testGuardCoalescesMultipleFilesystemEventsIntoOneRepair() async throws {
        let watcher = RecordingConfigDirectoryWatcher()
        let repairer = RecordingDeepSeekModelRepairer()
        repairer.result = .success(.repaired(model: "deepseek-v4-flash"))
        let guarder = DeepSeekModelGuard(
            watcher: watcher,
            repairer: repairer,
            debounceNanoseconds: 10_000_000
        )

        guarder.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        repairer.resetCallCount()

        watcher.emitChange()
        watcher.emitChange()
        watcher.emitChange()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(repairer.callCount, 1)
    }

    func testGuardStopAndRestartAreIdempotent() async throws {
        let watcher = RecordingConfigDirectoryWatcher()
        let repairer = RecordingDeepSeekModelRepairer()
        repairer.result = .success(.repaired(model: "deepseek-v4-flash"))
        let guarder = DeepSeekModelGuard(
            watcher: watcher,
            repairer: repairer,
            debounceNanoseconds: 10_000_000
        )

        guarder.start()
        guarder.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        guarder.stop()
        guarder.stop()
        let callsAfterStop = repairer.callCount
        watcher.emitChange()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(repairer.callCount, callsAfterStop)
        XCTAssertEqual(watcher.startCount, 1)
        XCTAssertEqual(watcher.stopCount, 1)
        XCTAssertEqual(guarder.state, .stopped)

        guarder.start()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(watcher.startCount, 2)
        XCTAssertEqual(repairer.callCount, callsAfterStop + 1)
    }
}
