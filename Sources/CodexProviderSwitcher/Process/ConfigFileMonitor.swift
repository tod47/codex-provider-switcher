import Darwin
import Foundation

protocol DeepSeekModelRepairing: Sendable {
    func repairDeepSeekModelIfNeeded() async throws -> DeepSeekModelGuardResult
}

protocol ConfigDirectoryWatching: AnyObject {
    func start(onChange: @escaping @Sendable () -> Void) throws
    func stop()
}

enum ConfigDirectoryWatcherError: Error, Equatable {
    case directoryUnavailable
}

final class ConfigDirectoryWatcher: ConfigDirectoryWatching, @unchecked Sendable {
    private let directoryURL: URL
    private let stateLock = NSLock()
    private var source: DispatchSourceFileSystemObject?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func start(onChange: @escaping @Sendable () -> Void) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard source == nil else {
            return
        }

        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw ConfigDirectoryWatcherError.directoryUnavailable
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        stateLock.lock()
        let source = self.source
        self.source = nil
        stateLock.unlock()

        source?.cancel()
    }

    deinit {
        stop()
    }
}

enum DeepSeekModelGuardState: Equatable, Sendable {
    case stopped
    case monitoring
    case repaired(model: String)
    case failed(String)
}

@MainActor
protocol DeepSeekModelGuarding: AnyObject {
    var state: DeepSeekModelGuardState { get }
    var onStateChange: ((DeepSeekModelGuardState) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class DeepSeekModelGuard: DeepSeekModelGuarding {
    private let watcher: any ConfigDirectoryWatching
    private let repairer: any DeepSeekModelRepairing
    private let debounceNanoseconds: UInt64
    private let retryDelaysNanoseconds: [UInt64]

    private(set) var state: DeepSeekModelGuardState = .stopped
    var onStateChange: ((DeepSeekModelGuardState) -> Void)?

    private var isRunning = false
    private var generation = 0
    private var pendingTask: Task<Void, Never>?
    private var repairInFlight = false
    private var needsAnotherRepair = false
    private var retryCount = 0
    private var stateResetTask: Task<Void, Never>?

    init(
        watcher: any ConfigDirectoryWatching,
        repairer: any DeepSeekModelRepairing,
        debounceNanoseconds: UInt64 = 250_000_000,
        retryDelaysNanoseconds: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000],
        onStateChange: ((DeepSeekModelGuardState) -> Void)? = nil
    ) {
        self.watcher = watcher
        self.repairer = repairer
        self.debounceNanoseconds = debounceNanoseconds
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.onStateChange = onStateChange
    }

    func start() {
        guard !isRunning else {
            return
        }

        generation += 1
        let currentGeneration = generation
        isRunning = true
        retryCount = 0
        needsAnotherRepair = false
        publish(.monitoring)

        do {
            try watcher.start { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleFilesystemChange()
                }
            }
        } catch {
            isRunning = false
            publish(.failed("无法监视 Codex 配置目录"))
            return
        }

        queueRepair(
            after: 0,
            generation: currentGeneration,
            allowsRetry: true
        )
    }

    func stop() {
        guard isRunning || state != .stopped else {
            return
        }

        isRunning = false
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        stateResetTask?.cancel()
        stateResetTask = nil
        repairInFlight = false
        needsAnotherRepair = false
        retryCount = 0
        watcher.stop()
        publish(.stopped)
    }

    private func handleFilesystemChange() {
        guard isRunning else {
            return
        }

        retryCount = 0
        queueRepair(
            after: debounceNanoseconds,
            generation: generation,
            allowsRetry: true
        )
    }

    private func queueRepair(
        after delayNanoseconds: UInt64,
        generation: Int,
        allowsRetry: Bool
    ) {
        guard isRunning, self.generation == generation else {
            return
        }

        if repairInFlight {
            needsAnotherRepair = true
            return
        }

        pendingTask?.cancel()
        pendingTask = Task { @MainActor [weak self] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
            } catch {
                return
            }

            guard let self,
                  self.isRunning,
                  self.generation == generation
            else {
                return
            }

            self.pendingTask = nil
            self.startRepair(
                generation: generation,
                allowsRetry: allowsRetry
            )
        }
    }

    private func startRepair(generation: Int, allowsRetry: Bool) {
        guard isRunning,
              self.generation == generation,
              !repairInFlight
        else {
            return
        }

        repairInFlight = true
        let repairer = self.repairer
        Task { @MainActor [weak self] in
            do {
                let result = try await repairer.repairDeepSeekModelIfNeeded()
                self?.finishRepair(
                    result: result,
                    generation: generation,
                    allowsRetry: allowsRetry
                )
            } catch {
                self?.finishRepair(
                    error: error,
                    generation: generation
                )
            }
        }
    }

    private func finishRepair(
        result: DeepSeekModelGuardResult,
        generation: Int,
        allowsRetry: Bool
    ) {
        guard isRunning, self.generation == generation else {
            repairInFlight = false
            return
        }

        repairInFlight = false
        switch result {
        case .ignored:
            publish(.monitoring)
            if allowsRetry, retryCount < retryDelaysNanoseconds.count {
                let delay = retryDelaysNanoseconds[retryCount]
                retryCount += 1
                queueRepair(
                    after: delay,
                    generation: generation,
                    allowsRetry: true
                )
            } else {
                retryCount = 0
                queuePendingEventRepairIfNeeded(generation: generation)
            }
        case let .repaired(model):
            retryCount = 0
            publish(.repaired(model: model))
            scheduleMonitoringStateReset(generation: generation)
            queuePendingEventRepairIfNeeded(generation: generation)
        }
    }

    private func finishRepair(error: Error, generation: Int) {
        guard isRunning, self.generation == generation else {
            repairInFlight = false
            return
        }

        repairInFlight = false
        retryCount = 0
        publish(.failed("DeepSeek 模型自动修复失败，请手动检查配置"))
        queuePendingEventRepairIfNeeded(generation: generation)
    }

    private func queuePendingEventRepairIfNeeded(generation: Int) {
        guard needsAnotherRepair else {
            return
        }
        needsAnotherRepair = false
        queueRepair(
            after: debounceNanoseconds,
            generation: generation,
            allowsRetry: true
        )
    }

    private func scheduleMonitoringStateReset(generation: Int) {
        stateResetTask?.cancel()
        stateResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            guard let self,
                  self.isRunning,
                  self.generation == generation,
                  case .repaired = self.state
            else {
                return
            }
            self.publish(.monitoring)
        }
    }

    private func publish(_ newState: DeepSeekModelGuardState) {
        state = newState
        onStateChange?(newState)
    }
}

extension SwitchTransactionCoordinator: DeepSeekModelRepairing {}
