import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class ProcessControllerTests: XCTestCase {
    func testProcessTableMatchesKnownCodexAppServerPath() throws {
        let runner = RecordingProcessCommandRunner(
            output: "123 /Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled\n"
        )
        let table = ProcessTable(commandRunner: runner)
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        XCTAssertTrue(table.hasCodexAppServer(for: appURL))
        XCTAssertEqual(runner.arguments, ["-axo", "pid=,command="])
    }

    func testProcessTableIgnoresUnrelatedProcesses() throws {
        let runner = RecordingProcessCommandRunner(
            output: "123 /usr/bin/other-process app-server\n"
        )
        let table = ProcessTable(commandRunner: runner)
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        XCTAssertFalse(table.hasCodexAppServer(for: appURL))
    }
}

private final class RecordingProcessCommandRunner: ProcessCommandRunning, @unchecked Sendable {
    let output: String
    private(set) var arguments: [String] = []

    init(output: String) {
        self.output = output
    }

    func run(executable: URL, arguments: [String]) throws -> String {
        self.arguments = arguments
        return output
    }
}
