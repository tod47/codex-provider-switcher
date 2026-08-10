import AppKit
import SwiftUI

@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private init() {}

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first(where: { $0.title == "Codex Provider Switcher" })
            ?? NSApp.windows.first
        window?.makeKeyAndOrderFront(nil)
    }
}

@main
@MainActor
struct CodexProviderSwitcherApp: App {
    @StateObject private var model: AppModel
    private let launchConfiguration: LaunchConfiguration

    init() {
        let configuration = (try? LaunchIntentParser.parse(arguments: CommandLine.arguments))
            ?? LaunchConfiguration(
                intent: .interactive,
                codexHomeOverride: nil,
                chatGPTApplicationOverride: nil
            )
        self.launchConfiguration = configuration
        self._model = StateObject(wrappedValue: Self.makeModel(configuration: configuration))
    }

    @SceneBuilder
    var body: some Scene {
        WindowGroup("Codex Provider Switcher") {
            if isInteractive {
                MainView(model: model)
            } else {
                IntentRunnerView(model: model, intent: launchConfiguration.intent)
            }
        }

        MenuBarExtra(
            "Codex Provider Switcher",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            if isInteractive {
                Button("切到 DeepSeek并重启 ChatGPT") {
                    Task { await model.switchToDeepSeek() }
                }
                .disabled(model.isBusy || model.currentMode == .deepSeek)

                Button("切回 GPT并重启 ChatGPT") {
                    Task { await model.switchToGPT() }
                }
                .disabled(model.isBusy || model.currentMode == .gpt)

                Divider()

                Button("打开主窗口") {
                    WindowRouter.shared.openMainWindow()
                }
                Button("仅检查") {
                    Task { await model.runPreflight() }
                }
                Button("测试当前 DeepSeek 请求") {
                    Task { await model.verifyCurrentProvider() }
                }
                .disabled(model.isBusy || model.currentMode != .deepSeek)
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                Text("正在执行一次性 provider 操作…")
            }
        }
    }

    private var isInteractive: Bool {
        if case .interactive = launchConfiguration.intent {
            return true
        }
        return false
    }

    private static func makeModel(configuration: LaunchConfiguration) -> AppModel {
        let homeDirectory = configuration.codexHomeOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
        let applicationURL = configuration.chatGPTApplicationOverride
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")

        guard let settings = try? SwitchSettings.defaultSettings(
            homeDirectory: homeDirectory,
            chatGPTApplicationURL: applicationURL
        ) else {
            fatalError("Unable to create provider switcher settings")
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? homeDirectory.appendingPathComponent("Library/Application Support")
        let supportRoot = applicationSupport.appendingPathComponent(
            "Codex Provider Switcher",
            isDirectory: true
        )
        let snapshotsRoot = supportRoot.appendingPathComponent("snapshots", isDirectory: true)
        let logsURL = supportRoot.appendingPathComponent("logs", isDirectory: true)
        let secretStore = KeychainSecretStore()
        let coordinator = SwitchTransactionCoordinator(
            settings: settings,
            transformer: CodexConfigTransformer(),
            snapshotStore: SnapshotStore(rootURL: snapshotsRoot),
            manifestStore: ManifestStore(url: supportRoot.appendingPathComponent("manifest.json")),
            secretStore: secretStore,
            preflight: EndpointPreflight(probe: URLSessionHTTPProbe()),
            processController: ChatGPTProcessController(
                applicationURL: settings.chatGPTApplicationURL
            ),
            // The v2 lock is a kernel-managed file lock. The old directory lock
            // can remain after an interrupted 0.1.0 transaction without blocking
            // the recovered implementation.
            lock: FileSwitchLock(url: supportRoot.appendingPathComponent("switch.lock.v2"))
        )

        return AppModel(
            coordinator: coordinator,
            snapshotsRootURL: snapshotsRoot,
            logsURL: logsURL,
            secretStore: secretStore,
            keychainService: settings.keychainService,
            keychainAccount: settings.keychainAccount
        )
    }
}

private struct IntentRunnerView: View {
    @ObservedObject var model: AppModel
    let intent: LaunchIntent
    @State private var didRun = false

    var body: some View {
        ProgressView("正在执行 provider 操作…")
            .frame(width: 360, height: 180)
            .task {
                guard !didRun else { return }
                didRun = true
                switch intent {
                case .interactive:
                    break
                case .switchTo(let mode):
                    if mode == .deepSeek {
                        await model.switchToDeepSeek()
                    } else {
                        await model.switchToGPT()
                    }
                case .checkOnly:
                    await model.runPreflight()
                }

                let alert = NSAlert()
                alert.messageText = "Codex Provider Switcher"
                alert.informativeText = model.statusMessage
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好")
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
    }
}
