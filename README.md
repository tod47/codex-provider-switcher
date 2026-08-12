# Codex Provider Switcher

原生 macOS SwiftUI 工具，用于在本机现有的 GPT provider 和实验性 DeepSeek provider 之间切换，并在切换后重启 ChatGPT/Codex 主程序，继续后续工作。

> 当前可下载版本：**v0.2.0**。需要 macOS 14 或更高版本。

## 下载安装

推荐从 GitHub Release 下载已经打包好的应用：

- [下载 DMG 安装包](https://github.com/tod47/codex-provider-switcher/releases/download/v0.2.0/Codex-Provider-Switcher-0.2.0.dmg)
- [下载 ZIP 便携包](https://github.com/tod47/codex-provider-switcher/releases/download/v0.2.0/Codex-Provider-Switcher-0.2.0.zip)
- [查看 v0.2.0 Release](https://github.com/tod47/codex-provider-switcher/releases/tag/v0.2.0)

DMG 中包含：

- `Codex Provider Switcher.app`：主应用；
- `Codex 切到 DeepSeek.app`：切换到 DeepSeek 并重启 ChatGPT；
- `Codex 切回 GPT.app`：恢复 GPT 配置并重启 ChatGPT；
- `Applications`：拖拽安装入口。

本版本使用 ad-hoc code signing，没有 Apple Developer ID notarization。第一次打开时如果 macOS 提示无法验证开发者，请在 Finder 中右键应用并选择“打开”。

## v0.2.0 功能

- 在 GPT 和实验性 DeepSeek provider 之间切换，并自动重启 ChatGPT/Codex 主程序；
- 切换前保存完整的 GPT `config.toml` 快照，失败时尽力恢复原配置和原 provider；
- DeepSeek 模式成功后常驻菜单栏，监视配置目录；
- 当 ChatGPT 的模型选择器把 DeepSeek 配置的根级 `model` 改成 GPT 模型时，自动恢复为 `deepseek-v4-flash`；
- 自动修复复用切换锁和原子替换，不与切换事务并发写配置；
- API Key 只保存到 macOS 钥匙串，并在启动 ChatGPT 时通过进程环境传递；
- 主窗口显示 provider、配置模型、endpoint、进程状态、验证结果和模型守护状态；
- 提供“仅检查”和“测试当前请求”操作，后者只在用户主动点击时发送最小 Responses 请求；
- 应用不读取、不修改 Codex 历史数据库、WAL/SHM、会话 JSONL 或其他历史桶。

## 使用方式

### 主应用

打开 `Codex Provider Switcher.app` 后：

1. 观察“当前模式”和“实际 provider 状态”；
2. 点击“切到 DeepSeek并重启 ChatGPT”或“切回 GPT并重启 ChatGPT”；
3. 切换完成后应用会留在菜单栏，DeepSeek 模式下模型防误改守护会继续运行；
4. 需要确认网络配置时使用“仅检查”；需要确认实际响应模型时使用“测试当前请求”。

第一次使用 DeepSeek 时，应用会要求输入 API Key。密钥只写入钥匙串服务 `Codex Provider Switcher`，不会写入 `config.toml`、命令行参数、桌面快捷方式或日志。

### 桌面快捷方式和命令行

桌面快捷方式只传递模式参数，不包含密钥。主 executable 也支持：

```bash
.build/release/CodexProviderSwitcher --mode=deepseek
.build/release/CodexProviderSwitcher --mode=gpt
.build/release/CodexProviderSwitcher --check
```

行为区别如下：

- `--mode=deepseek`：执行 DeepSeek 切换；成功后保持菜单栏常驻并启动模型守护；
- `--mode=gpt`：执行 GPT 恢复；成功后保持菜单栏常驻，但不运行 DeepSeek 模型守护；
- `--check`：只做一次 endpoint/凭据预检，显示结果后退出；
- 无参数：进入交互式主窗口和菜单栏模式。

测试或其他配置目录可以注入路径：

```bash
.build/release/CodexProviderSwitcher \
  --mode=deepseek \
  --codex-home /path/to/.codex \
  --chatgpt-app /path/to/ChatGPT.app
```

## DeepSeek 模型防误改

配置中的 `model_provider = "custom"` 是 provider ID，不是模型名。真正决定发送给 DeepSeek 的模型是根级配置：

```toml
model_provider = "custom"
model = "deepseek-v4-flash"

[model_providers.custom]
base_url = "https://api.deepseek.com"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
requires_openai_auth = false
```

常驻守护器只有在 provider 的 endpoint、协议、环境变量名和鉴权声明仍然匹配 DeepSeek 时，才会把被改动的根级 `model` 恢复为设置中的 DeepSeek 模型。GPT 配置、未知 provider 和其他 TOML 内容不会被守护器自动修改。

守护器对切换锁冲突只做有限次数重试，不会无限轮询。它保护的是下一次请求读取到的本地配置，不能撤回已经提交的请求、修改服务端响应或重写 ChatGPT/Codex 已经缓存的会话状态。

## 数据边界和恢复

应用只写当前 Codex 配置文件，以及自己的 Application Support 目录：

```text
~/Library/Application Support/Codex Provider Switcher/
```

自己的目录中可能包含 `manifest.json`、`snapshots/`、`logs/` 和由操作系统管理的 `switch.lock.v2`。应用不会打开或迁移：

- `state_5.sqlite`；
- SQLite 的 `-wal` 和 `-shm` 文件；
- 会话 JSONL；
- 历史线程表或其他历史桶。

如果切换过程中的退出、写入、启动或验证失败，工具会尽力恢复原始完整配置并重新启动原 provider。切换前生成的 GPT 快照可以在主窗口中打开，供人工恢复使用。

## 已知限制

DeepSeek provider 是实验性接入。预检或模型目录检查通过，不等于已经验证工具调用、流式事件、图片输入、上下文缓存或全部旧会话兼容性。

不要把同一个正在进行的线程在 DeepSeek 和 GPT 之间反复切换后继续使用。不同 provider 可能写入不同的 Responses 内容块，切回 GPT 后旧线程重放可能出现：

```text
Invalid 'input[6].content': array too long.
```

遇到这种情况，请在切回 GPT 后新建一个 GPT 线程，或手动复制必要的文字摘要继续。工具不会为了修复这类兼容性问题而修改历史数据库或会话文件。

本工具是本地实验工具，不是 OpenAI 官方 ChatGPT Desktop 的内置 provider 功能。客户端版本、账号能力、服务端协议和网络环境都可能影响结果。

## 从源码构建和打包

开发环境需要 macOS 14 或更高版本、Swift 6 工具链：

```bash
swift build -c release
```

运行完整测试：

```bash
swift test
```

生成带图标的应用、桌面快捷方式、DMG 和 ZIP：

```bash
bash scripts/package-app.sh /tmp/codex-provider-switcher-staging 0.2.0
```

将 staging 中的应用安装到当前用户的 Applications 和桌面：

```bash
bash scripts/install-desktop-launchers.sh /tmp/codex-provider-switcher-staging
```

安装脚本只会替换 bundle identifier 为 `local.codex.provider-switcher` 的同项目目标；如果发现同名目标属于其他应用，会停止并报告冲突。

## 发布检查状态

`v0.2.0` 发布时已执行：

- release 构建；
- shell 脚本语法检查；
- app bundle 的 `Info.plist` 检查；
- `.icns` 图标存在性检查；
- ad-hoc code signature 检查；
- DMG/ZIP 内容检查；
- 敏感路径和敏感内容检查。

本次发布按维护者要求没有运行完整单元测试，也没有执行真实 provider 切换。贡献代码时请按照 [CONTRIBUTING.md](CONTRIBUTING.md) 运行完整测试，并使用临时 Codex home 验证。

## 项目文档

以下链接固定到当前发布版本，确保从默认分支首页访问时也不会因为分支内容不同而断链：

- [使用说明](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/docs/usage.md)
- [架构说明](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/docs/architecture.md)
- [安全边界](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/SECURITY.md)
- [贡献指南](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/CONTRIBUTING.md)
- [MIT License](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/LICENSE)

## 许可证

本项目按 MIT License 发布，详见 [LICENSE](https://github.com/tod47/codex-provider-switcher/blob/v0.2.0/LICENSE)。
