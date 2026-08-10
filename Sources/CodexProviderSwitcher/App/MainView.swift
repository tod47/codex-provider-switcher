import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showingDeepSeekConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex Provider Switcher")
                    .font(.title2.weight(.semibold))
                Text("安全切换 provider，并重启 ChatGPT 继续当前任务")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack {
                    Text("当前模式")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.currentMode.displayName)
                        .font(.headline)
                        .foregroundStyle(modeColor)
                }
            }

            if let providerStatus = model.providerStatus {
                GroupBox("实际 provider 状态") {
                    VStack(alignment: .leading, spacing: 7) {
                        statusRow("Provider", providerStatus.mode.displayName)
                        statusRow("配置模型", providerStatus.configuredModel ?? "未读取")
                        statusRow("Endpoint", providerStatus.endpoint ?? "未读取")
                        statusRow("Codex 进程", providerStatus.processRunning ? "已运行" : "未运行")
                        if let verification = providerStatus.verification {
                            statusRow("验证", verification.state.displayName)
                            if !verification.messages.isEmpty {
                                Text(verification.messages.joined(separator: "；"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } else {
                            statusRow("验证", "尚未验证")
                        }
                    }
                }
            }

            VStack(spacing: 10) {
                Button {
                    showingDeepSeekConfirmation = true
                } label: {
                    Label("切到 DeepSeek并重启 ChatGPT", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.currentMode == .deepSeek)

                Button {
                    Task { await model.switchToGPT() }
                } label: {
                    Label("切回 GPT并重启 ChatGPT", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.currentMode == .gpt)
            }

            HStack(spacing: 10) {
                Button("仅检查") {
                    Task { await model.runPreflight() }
                }
                .disabled(model.isBusy)

                Button("测试当前请求") {
                    Task { await model.verifyCurrentProvider() }
                }
                .disabled(model.isBusy || model.currentMode != .deepSeek)

                Button("打开备份") {
                    model.revealSnapshots()
                }

                Button("打开日志") {
                    model.revealLogs()
                }
            }
            .buttonStyle(.bordered)

            Divider()

            HStack(alignment: .top, spacing: 8) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                Text(model.statusMessage.isEmpty ? "等待操作。" : model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Label(
                "右下角的 ChatGPT 模型列表不代表 Codex provider；请以这里的 provider、配置模型和验证结果为准。DeepSeek 为实验性接入。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 360)
        .task {
            await model.refresh()
        }
        .alert("确认切换到 DeepSeek？", isPresented: $showingDeepSeekConfirmation) {
            Button("取消", role: .cancel) {}
            Button("继续", role: .destructive) {
                Task { await model.switchToDeepSeek() }
            }
        } message: {
            Text("应用会先备份 config.toml，优雅退出 ChatGPT，原子替换 provider 配置，再重新启动 ChatGPT。历史数据库不会被修改。")
        }
        .sheet(isPresented: $model.showDeepSeekKeyPrompt) {
            DeepSeekKeyPromptView(model: model)
        }
    }

    private var modeColor: Color {
        switch model.currentMode {
        case .gpt: return .blue
        case .deepSeek: return .orange
        case .unknown: return .secondary
        }
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

private struct DeepSeekKeyPromptView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("保存 DeepSeek API Key")
                .font(.title3.weight(.semibold))
            Text("密钥只保存到 macOS 钥匙串，不会写入 config.toml、命令行参数或日志。")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("DeepSeek API Key", text: $model.deepSeekKeyInput)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    model.deepSeekKeyInput = ""
                    model.showDeepSeekKeyPrompt = false
                    dismiss()
                }
                Button("保存并切换") {
                    Task { await model.saveDeepSeekKeyAndSwitch() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.deepSeekKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !model.statusMessage.isEmpty {
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
