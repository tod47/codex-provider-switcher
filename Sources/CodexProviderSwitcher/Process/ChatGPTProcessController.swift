import AppKit
import Foundation

enum ChatGPTProcessError: Error, Equatable {
    case applicationNotFound(URL)
    case terminationRejected
    case launchFailed(String)
}

protocol ChatGPTProcessControlling: Sendable {
    func isRunning() -> Bool
    func requestTermination() async throws
    func waitUntilStopped(timeout: Duration) async -> Bool
    func launch(environment: [String: String]) throws
    func waitUntilRunning(timeout: Duration) async -> Bool
}

struct ChatGPTProcessController: ChatGPTProcessControlling {
    let applicationURL: URL
    let processTable: ProcessTable
    let sleeper: any Sleeper
    let bundleIdentifier: String

    init(
        applicationURL: URL,
        processTable: ProcessTable = ProcessTable(),
        sleeper: any Sleeper = TaskSleeper(),
        bundleIdentifier: String = "com.openai.codex"
    ) {
        self.applicationURL = applicationURL
        self.processTable = processTable
        self.sleeper = sleeper
        self.bundleIdentifier = bundleIdentifier
    }

    func isRunning() -> Bool {
        !runningApplications().isEmpty || processTable.hasChatGPTApplication(for: applicationURL)
    }

    func requestTermination() async throws {
        for application in runningApplications() {
            guard application.terminate() else {
                throw ChatGPTProcessError.terminationRejected
            }
        }
    }

    func waitUntilStopped(timeout: Duration) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        repeat {
            if !isRunning() {
                return true
            }
            await sleeper.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return !isRunning()
    }

    func launch(environment: [String: String]) throws {
        let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/ChatGPT")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ChatGPTProcessError.applicationNotFound(applicationURL)
        }

        let process = Process()
        process.executableURL = executableURL
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ChatGPTProcessError.launchFailed(String(describing: error))
        }
    }

    func waitUntilRunning(timeout: Duration) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout.timeInterval)
        repeat {
            if isRunning() {
                return true
            }
            await sleeper.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return isRunning()
    }

    private func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
