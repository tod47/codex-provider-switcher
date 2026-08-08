# Codex Provider Switcher

一个原生 macOS SwiftUI 工具，用于在本机现有 GPT provider 和实验性 DeepSeek provider 之间切换，并在切换后重启 ChatGPT/Codex 主程序。

这个项目的边界很明确：

- 只修改当前用户的 Codex config.toml provider 配置；
- 切换前创建带 SHA-256 的完整配置快照；
- 使用同目录临时文件和原子替换；
- API Key 只保存到 macOS 钥匙串，不写入 TOML、参数、桌面包装器或日志；
- 不读取、不修改 state_5.sqlite、其 WAL/SHM 文件、会话 JSONL 或历史线程记录；
- DeepSeek 接入是实验性的，不能保证 ChatGPT/Codex 客户端、Responses 兼容层和旧会话全部兼容。

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
- “打开备份”：查看可用于人工恢复的配置快照。

第一次使用 DeepSeek 时，应用会弹出 SecureField。API Key 会存入钥匙串服务 Codex Provider Switcher，不会被写进配置文件。

桌面包装器只传递 --mode=deepseek 或 --mode=gpt，不携带任何密钥。为了便于测试和复用，也支持：

    .build/release/CodexProviderSwitcher --check
    .build/release/CodexProviderSwitcher --mode=deepseek --codex-home /path/to/.codex --chatgpt-app /path/to/ChatGPT.app

没有参数时进入交互式 UI；有一次性 intent 时执行一次、显示结果并退出。

## 数据位置和恢复

应用状态位于当前用户的：

    ~/Library/Application Support/Codex Provider Switcher/

其中包括 manifest.json、snapshots/ 和预留的 logs/ 目录。快照文件保存的是完整 config.toml，并带有哈希校验。

如果切换过程中 ChatGPT 未能退出，应用会在写配置前停止操作。如果写入或启动失败，应用会尽力恢复原配置、重启原 provider，并把事务标记为 rolledBack。如果主程序或系统在事务中途异常退出，请先不要删除快照，再从最近的 GPT 快照人工恢复 config.toml，然后重新打开 ChatGPT。

## 兼容性说明

本工具只把 DeepSeek endpoint 配置为 Codex 的 responses wire API，并通过 HEAD 请求做轻量预检。预检通过不等于真实模型请求一定兼容；工具不会自动发送 completion，也不会验证工具调用、流式事件、上下文缓存、图片输入或会话恢复能力。

官方 Codex 配置参考：

- https://learn.chatgpt.com/docs/config-file/config-reference
- https://learn.chatgpt.com/docs/config-file/config-advanced

第三方 provider 接入可能受客户端版本、账号能力、服务端协议和地区网络影响。请把它当作可回滚的本地实验工具，不要把它当作 OpenAI 官方 ChatGPT Desktop 的内置 provider 功能。
