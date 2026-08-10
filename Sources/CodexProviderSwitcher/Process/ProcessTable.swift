import Foundation

protocol ProcessCommandRunning: Sendable {
    func run(executable: URL, arguments: [String]) throws -> String
}

struct FoundationProcessCommandRunner: ProcessCommandRunning {
    func run(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: output, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

struct ProcessTable: Sendable {
    let commandRunner: any ProcessCommandRunning
    let psURL: URL

    init(
        commandRunner: any ProcessCommandRunning = FoundationProcessCommandRunner(),
        psURL: URL = URL(fileURLWithPath: "/bin/ps")
    ) {
        self.commandRunner = commandRunner
        self.psURL = psURL
    }

    func hasChatGPTApplication(for applicationURL: URL) -> Bool {
        let expectedExecutable = applicationURL
            .appendingPathComponent("Contents/MacOS/ChatGPT")
            .path
        guard let output = try? commandRunner.run(
            executable: psURL,
            arguments: ["-axo", "pid=,command="]
        ) else {
            return false
        }

        return output.split(whereSeparator: \.isNewline).contains { line in
            let text = String(line)
            return text.contains(expectedExecutable)
        }
    }
}
