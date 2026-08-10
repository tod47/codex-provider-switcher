import AppKit
import Foundation
import SwiftUI

enum LaunchIntent: Equatable {
    case interactive
    case switchTo(ProviderMode)
    case checkOnly
}

enum LaunchIntentParsingError: Error, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidMode(String)
    case conflictingIntent
    case duplicateArgument(String)
}

struct LaunchConfiguration: Equatable {
    let intent: LaunchIntent
    let codexHomeOverride: URL?
    let chatGPTApplicationOverride: URL?
}

struct LaunchIntentParser {
    static func parse(arguments: [String]) throws -> LaunchConfiguration {
        var tokens = arguments
        if let first = tokens.first, !first.hasPrefix("-") {
            tokens.removeFirst()
        }

        var intent: LaunchIntent = .interactive
        var codexHomeOverride: URL?
        var chatGPTApplicationOverride: URL?

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--check" {
                guard case .interactive = intent else {
                    throw LaunchIntentParsingError.conflictingIntent
                }
                intent = .checkOnly
                index += 1
                continue
            }

            if token.hasPrefix("--mode=") {
                guard case .interactive = intent else {
                    throw LaunchIntentParsingError.conflictingIntent
                }
                let rawMode = String(token.dropFirst("--mode=".count))
                switch rawMode {
                case "deepseek":
                    intent = .switchTo(.deepSeek)
                case "gpt":
                    intent = .switchTo(.gpt)
                default:
                    throw LaunchIntentParsingError.invalidMode(rawMode)
                }
                index += 1
                continue
            }

            if token == "--codex-home" || token == "--chatgpt-app" {
                guard index + 1 < tokens.count else {
                    throw LaunchIntentParsingError.missingValue(token)
                }
                let value = tokens[index + 1]
                guard !value.isEmpty, !value.hasPrefix("--") else {
                    throw LaunchIntentParsingError.missingValue(token)
                }
                let url = URL(fileURLWithPath: value)
                if token == "--codex-home" {
                    guard codexHomeOverride == nil else {
                        throw LaunchIntentParsingError.duplicateArgument(token)
                    }
                    codexHomeOverride = url
                } else {
                    guard chatGPTApplicationOverride == nil else {
                        throw LaunchIntentParsingError.duplicateArgument(token)
                    }
                    chatGPTApplicationOverride = url
                }
                index += 2
                continue
            }

            throw LaunchIntentParsingError.unknownArgument(token)
        }

        return LaunchConfiguration(
            intent: intent,
            codexHomeOverride: codexHomeOverride,
            chatGPTApplicationOverride: chatGPTApplicationOverride
        )
    }
}

protocol ProviderSwitching: Sendable {
    func currentMode() throws -> ProviderMode
    func currentStatus() throws -> ProviderStatus
    func switchTo(_ targetMode: ProviderMode) async throws -> SwitchResult
    func verifyCurrentProvider() async throws -> ProviderStatus
    func checkPreflight() async throws -> EndpointPreflightReport
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var currentMode: ProviderMode = .unknown
    @Published private(set) var providerStatus: ProviderStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastSnapshotURL: URL?
    @Published var showDeepSeekKeyPrompt = false
    @Published var deepSeekKeyInput = ""

    private let coordinator: any ProviderSwitching
    private let snapshotsRootURL: URL
    private let logsURL: URL
    private let secretStore: (any SecretStore)?
    private let keychainService: String?
    private let keychainAccount: String?
    private let openURL: (URL) -> Void

    init(
        coordinator: any ProviderSwitching,
        snapshotsRootURL: URL,
        logsURL: URL,
        secretStore: (any SecretStore)? = nil,
        keychainService: String? = nil,
        keychainAccount: String? = nil,
        openURL: @escaping (URL) -> Void = { url in
            _ = NSWorkspace.shared.open(url)
        }
    ) {
        self.coordinator = coordinator
        self.snapshotsRootURL = snapshotsRootURL
        self.logsURL = logsURL
        self.secretStore = secretStore
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.openURL = openURL
        let initialStatus = try? coordinator.currentStatus()
        self.providerStatus = initialStatus
        self.currentMode = initialStatus?.mode ?? (try? coordinator.currentMode()) ?? .unknown
    }

    func refresh() async {
        do {
            let status = try coordinator.currentStatus()
            providerStatus = status
            currentMode = status.mode
            statusMessage = status.summary
        } catch {
            statusMessage = "无法读取当前配置，请检查 Codex 配置文件。"
        }
    }

    func switchToDeepSeek() async {
        await switchTo(.deepSeek)
    }

    func switchToGPT() async {
        await switchTo(.gpt)
    }

    func verifyCurrentProvider() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在发送最小测试请求，确认实际响应模型…"
        defer { isBusy = false }

        do {
            let status = try await coordinator.verifyCurrentProvider()
            providerStatus = status
            currentMode = status.mode
            statusMessage = status.summary
        } catch let error as SwitchError {
            statusMessage = error.statusMessage
        } catch {
            statusMessage = "实际 provider 测试失败，配置未修改。"
        }
    }

    func runPreflight() async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在检查 DeepSeek provider…"
        defer { isBusy = false }

        do {
            let report = try await coordinator.checkPreflight()
            if report.reachable, report.responsesDeclared {
                statusMessage = "预检通过：DeepSeek endpoint 可访问。"
            } else {
                statusMessage = "预检未通过：\(report.messages.joined(separator: "；"))"
                if report.messages.contains("DeepSeek API Key is missing") {
                    showDeepSeekKeyPrompt = true
                }
            }
        } catch {
            statusMessage = "预检失败：无法安全读取 DeepSeek 配置。"
        }
    }

    func saveDeepSeekKeyAndSwitch() async {
        guard let secretStore, let keychainService, let keychainAccount else {
            statusMessage = "当前实例没有配置可用的钥匙串存储。"
            return
        }
        let value = deepSeekKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            statusMessage = "请输入 DeepSeek API Key。"
            return
        }

        do {
            try secretStore.write(value, service: keychainService, account: keychainAccount)
            deepSeekKeyInput = ""
            showDeepSeekKeyPrompt = false
            await switchToDeepSeek()
        } catch {
            statusMessage = "无法保存 API Key 到钥匙串。"
        }
    }

    func revealSnapshots() {
        try? FileManager.default.createDirectory(at: snapshotsRootURL, withIntermediateDirectories: true)
        openURL(snapshotsRootURL)
    }

    func revealLogs() {
        let target = FileManager.default.fileExists(atPath: logsURL.path)
            ? logsURL
            : logsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        openURL(target)
    }

    private func switchTo(_ targetMode: ProviderMode) async {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = "正在切换到 \(targetMode.displayName)，准备重启 ChatGPT…"
        defer { isBusy = false }

        do {
            let result = try await coordinator.switchTo(targetMode)
            currentMode = result.targetMode
            providerStatus = result.status
            if let snapshotID = result.snapshotID {
                lastSnapshotURL = snapshotsRootURL
                    .appendingPathComponent(snapshotID, isDirectory: true)
                    .appendingPathComponent("config.toml")
            }
            statusMessage = result.status.summary
        } catch let error as SwitchError {
            if targetMode == .deepSeek, case let .preflightFailed(messages) = error,
               messages.contains("DeepSeek API Key is missing") {
                showDeepSeekKeyPrompt = true
                statusMessage = "请先保存 DeepSeek API Key，再开始切换。"
            } else {
                statusMessage = error.statusMessage
            }
        } catch {
            statusMessage = "切换失败，配置保持不变。"
        }
    }
}

extension ProviderMode {
    var displayName: String {
        switch self {
        case .gpt: return "GPT"
        case .deepSeek: return "DeepSeek（实验性）"
        case .unknown: return "未知"
        }
    }
}

private extension ProviderStatus {
    var summary: String {
        let modelText = configuredModel.map { "，模型：\($0)" } ?? ""
        let processText = processRunning ? "Codex 已运行" : "Codex 尚未运行"
        var verificationText = verification?.messages.joined(separator: "；") ?? "尚未验证"
        if let actualResponseModel = verification?.actualResponseModel {
            verificationText += "；实际响应模型：\(actualResponseModel)"
        }
        return "当前 provider：\(mode.displayName)\(modelText)。\(processText)。\(verificationText)。"
    }
}

private extension SwitchError {
    var statusMessage: String {
        switch self {
        case .alreadyRunning:
            return "已有一次切换正在进行，请稍后再试。"
        case .lockFailed:
            return "无法取得切换锁，配置保持不变。"
        case .unsupportedTarget:
            return "不支持的目标 provider。"
        case .unknownCurrentMode:
            return "无法确认当前 provider，已停止操作，配置保持不变。"
        case let .preflightFailed(messages):
            return "预检未通过：\(messages.joined(separator: "；"))"
        case .secretStoreFailed:
            return "无法安全读取 DeepSeek API Key。"
        case .configurationReadFailed:
            return "无法读取 Codex 配置文件。"
        case .configurationTransformFailed:
            return "无法安全转换 Codex provider 配置。"
        case .snapshotFailed:
            return "无法创建或读取配置备份，未继续操作。"
        case .manifestFailed:
            return "无法更新本地切换状态，未继续操作。"
        case .chatGPTTerminationFailed:
            return "ChatGPT 拒绝退出，未写入配置。"
        case .chatGPTDidNotStop:
            return "ChatGPT 未能在超时内退出，未写入配置。"
        case .configurationWriteFailed:
            return "配置写入失败，已保持原配置并尝试恢复 ChatGPT。"
        case .launchFailed:
            return "ChatGPT 启动失败，已尝试恢复原 provider。"
        case .chatGPTDidNotStart:
            return "ChatGPT 未能在超时内启动，已尝试恢复原 provider。"
        case .configurationVerificationFailed:
            return "重启后配置与目标 provider 不一致，已尝试恢复原 provider。"
        case let .providerVerificationFailed(messages):
            return "provider 验证未通过：\(messages.joined(separator: "；"))，已尝试恢复原 provider。"
        case .rolledBack:
            return "切换失败，已恢复原配置并重启 ChatGPT。"
        }
    }
}
