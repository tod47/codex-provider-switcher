import Foundation

protocol Clock: Sendable {
    var now: Date { get }
}

struct SystemClock: Clock {
    var now: Date { Date() }
}

protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async
}

struct TaskSleeper: Sleeper {
    func sleep(for duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}
