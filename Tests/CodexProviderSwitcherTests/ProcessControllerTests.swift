import Foundation
import XCTest

@testable import CodexProviderSwitcher

final class ProcessControllerTests: XCTestCase {
    func testProcessCommandRunnerDrainsLargeOutputBeforeWaitingForTheChild() throws {
        let runner = FoundationProcessCommandRunner()
        let output = try runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes x | head -c 200000"]
        )

        XCTAssertEqual(output.utf8.count, 200_000)
    }

    func testProcessTableMatchesChatGPTApplicationExecutablePath() throws {
        let runner = RecordingProcessCommandRunner(
            output: "123 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT --some-flag\n"
        )
        let table = ProcessTable(commandRunner: runner)
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        XCTAssertTrue(table.hasChatGPTApplication(for: appURL))
        XCTAssertEqual(runner.arguments, ["-axo", "pid=,command="])
    }

    func testProcessTableDoesNotTreatAnOrphanedCodexAppServerAsChatGPT() throws {
        let runner = RecordingProcessCommandRunner(
            output: "123 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://\n"
        )
        let table = ProcessTable(commandRunner: runner)
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        XCTAssertFalse(table.hasChatGPTApplication(for: appURL))
    }

    func testProcessTableIgnoresUnrelatedProcesses() throws {
        let runner = RecordingProcessCommandRunner(
            output: "123 /usr/bin/other-process app-server\n"
        )
        let table = ProcessTable(commandRunner: runner)
        let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")

        XCTAssertFalse(table.hasChatGPTApplication(for: appURL))
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
