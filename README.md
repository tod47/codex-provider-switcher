# Codex Provider Switcher

一个原生 macOS SwiftUI 工具，用于在本机现有 GPT provider 和实验性 DeepSeek provider 之间切换，并在切换后重启 ChatGPT/Codex 主程序。

这个项目的边界很明确：

- 只修改当前用户的 Codex config.toml provider 配置；
- 切换前创建带 SHA-256 的完整配置快照；
- 使用同目录临时文件和原子替换；
- API Key 只保存到 macOS 钥匙串，不写入 TOML、参数、桌面包装器或日志；
- 不读取、不修改 state_5.sqlite、其 WAL/SHM 文件、会话 JSONL 或历史线程记录；
- DeepSeek 接入是实验性的，默认 Responses endpoint 为 `https://api.deepseek.com`，模型为 `deepseek-v4-flash`；仍不能保证 ChatGPT/Codex 客户端和旧会话全部兼容。

目前没有为仓库选择开源许可证；在发布到 GitHub 前，请先补充许可证和项目归属信息。

贡献和安全边界见 CONTRIBUTING.md、SECURITY.md；分层、事务阶段和数据不变式见 docs/architecture.md。

## 构建和测试

需要 macOS 14 或更高版本、Swift 6 工具链：

    swift test
    swift build -c debug

正式打包到一个临时目录：

    bash scripts/package-app.sh /tmp/codex-provider-switcher-staging

脚本会生成：

- Codex Provider Switcher.app
- Codex 切到 DeepSeek.app
- Codex 切回 GPT.app

安装到当前用户的 Applications 和桌面：

    bash scripts/install-desktop-launchers.sh /tmp/codex-provider-switcher-staging

安装脚本只会替换 bundle identifier 为 local.codex.provider-switcher 的同项目目标。如果同名目标属于其他应用，会停止并报告冲突；已有的 DeepSeek V4 Flash Max.command 文件不会被碰触。

## 使用方式

打开主应用后，先观察“当前模式”，再选择：

- “切到 DeepSeek并重启 ChatGPT”：先做 endpoint 预检，备份当前 GPT 配置，优雅退出 ChatGPT，写入 DeepSeek provider 配置，再启动 ChatGPT；
- “切回 GPT并重启 ChatGPT”：从最近一次 GPT 快照恢复完整配置，再启动 ChatGPT；
- “仅检查”：只检查钥匙串中的凭据、Responses 声明和 endpoint 可访问性，不写配置、不退出 ChatGPT；
- “测试当前请求”：仅在 DeepSeek 模式下发送一个最小 Responses 请求，读取返回的 `model` 字段，确认实际响应模型；这一步可能产生极少量 API 用量，需要手动点击才会执行；
- “打开备份”：查看可用于人工恢复的配置快照。

第一次使用 DeepSeek 时，应用会弹出 SecureField。API Key 会存入钥匙串服务 Codex Provider Switcher，不会被写进配置文件。

桌面包装器只传递 --mode=deepseek 或 --mode=gpt，不携带任何密钥。为了便于测试和复用，也支持：

    .build/release/CodexProviderSwitcher --check
    .build/release/CodexProviderSwitcher --mode=deepseek --codex-home /path/to/.codex --chatgpt-app /path/to/ChatGPT.app

没有参数时进入交互式 UI；有一次性 intent 时执行一次、显示结果并退出。

## 数据位置和恢复

应用状态位于当前用户的：

    ~/Library/Application Support/Codex Provider Switcher/

其中包括 manifest.json、snapshots/、预留的 logs/ 目录和由操作系统管理的 `switch.lock.v2` 锁文件。快照文件保存的是完整 config.toml，并带有哈希校验。

如果切换过程中 ChatGPT 未能退出，应用会在写配置前停止操作。如果写入或启动失败，应用会尽力恢复原配置、重启原 provider，并把事务标记为 rolledBack。如果主程序或系统在事务中途异常退出，请先不要删除快照，再从最近的 GPT 快照人工恢复 config.toml，然后重新打开 ChatGPT。

## 兼容性说明

切换完成后，主窗口会显示当前 provider、配置模型、endpoint、Codex 进程状态和验证结果。DeepSeek 会在重启后使用鉴权的 `GET /models` 检查配置模型是否出现在 provider 的模型目录中；点击“测试当前请求”后，应用才会发送一个最小 Responses 请求，并把返回的实际 `model` 写入状态。模型目录验证不等于已经验证工具调用、流式事件、上下文缓存、图片输入或会话恢复能力。ChatGPT 右下角的原生模型列表不作为 provider 状态来源。

官方 Codex 配置参考：

- https://learn.chatgpt.com/docs/config-file/config-reference
- https://learn.chatgpt.com/docs/config-file/config-advanced

第三方 provider 接入可能受客户端版本、账号能力、服务端协议和地区网络影响。请把它当作可回滚的本地实验工具，不要把它当作 OpenAI 官方 ChatGPT Desktop 的内置 provider 功能。

## 当前版本验证

当前实现已经通过 43 条 Swift 单元测试和 release build；测试覆盖配置转换、快照原子替换、Keychain 抽象、endpoint 预检、模型目录验证、实际响应模型验证、进程生命周期、进程表大输出、事务回滚、UI view-model、命令行 intent、锁并发和历史 sentinel 不变式。

打包验收使用临时 staging 目录，三个 app bundle 均通过 plist 检查和 ad-hoc code-sign 验证。自动化验收不会点击 DeepSeek 切换；首次真实切换必须由用户明确在 UI 中触发。

验证真实 Codex home 时，不应把普通 sqlite3 只读查询后的 WAL/SHM 哈希变化误判为应用写入证据：SQLite 读取器可能更新共享内存元数据。应用自身不连接历史数据库，历史保护以不打开数据库和事务测试中的 sentinel 为边界。
