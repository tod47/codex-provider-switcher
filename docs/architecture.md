# Architecture

Codex Provider Switcher 是一个 SwiftPM macOS executable。它把 UI、事务编排、配置转换、快照、安全存储、endpoint 预检和 ChatGPT 生命周期控制分开，便于在开源时替换本地路径和测试依赖。

## 分层

- Domain：ProviderMode、DeepSeekSettings 和 SwitchSettings，只负责可编码状态和输入校验。
- Config：对 provider 相关的 TOML 行做窄范围转换；SnapshotStore 保存完整 config.toml 的哈希快照；ManifestStore 用原子 JSON 写入事务状态。
- Security：KeychainSecretStore 使用 macOS Generic Password 保存 API Key；EnvFileImporter 只提供一次性导入能力，且不把密钥写入配置。
- Provider：EndpointPreflight 检查 HTTP/HTTPS endpoint、responses wire API 和凭据是否存在，并用 HEAD 做轻量可达性探测；DeepSeekModelCatalogChecking 在重启后用鉴权的 `GET /models` 验证目标模型是否存在；DeepSeekModelResponseTesting 只在用户点击测试按钮后发送最小 Responses 请求并读取返回的实际 `model`。
- Process：ChatGPTProcessController 识别已运行的 ChatGPT/Codex app-server，优雅退出、等待停止，再以受控环境重新启动并等待进程出现。
- Switch：SwitchTransactionCoordinator 串联锁、快照、停止、原子写入、启动、配置/进程验证、完成和回滚。
- App：SwiftUI 主窗口、MenuBarExtra、钥匙串输入 sheet 和一次性命令行 intent。
- scripts：生成主 app 和两个无密钥桌面包装器，并在安装前检查目标 bundle identifier。

## 正常事务

一次从 GPT 到 DeepSeek 的切换顺序是：

    acquire lock
    read and classify config
    read Keychain and run preflight
    save complete GPT snapshot
    record preparing/snapshotted state
    request ChatGPT termination and confirm stopped
    atomically replace config.toml
    launch ChatGPT with DEEPSEEK_API_KEY in the process environment only
    wait for ChatGPT / Codex app-server
    verify target config and provider model availability
    record completed state and visible verification result
    release lock

切回 GPT 时读取最近的 GPT snapshot，并且不设置 DeepSeek 环境变量。写入失败、启动失败或事务后半段异常时，会尝试恢复原始完整配置、重新启动原 provider，并把 manifest 标记为 rolledBack。

如果 ChatGPT 未能停止，事务在原子替换前终止；原配置和历史 sentinel 应保持不变。锁使用 app-support 下的内核级文件锁，避免两个切换同时进行，并由操作系统在切换器进程异常退出时自动释放。当前版本使用 `switch.lock.v2`；早期版本遗留的 `switch.lock` 目录不会阻塞新实现。

## 数据边界

应用只写自己的 Application Support 子目录和当前 provider 配置文件。它不打开、不更新、不迁移：

- state_5.sqlite；
- SQLite 的 -wal 和 -shm 伴随文件；
- 会话 JSONL；
- 历史线程表和其他 Codex 历史桶。

配置转换保留 model_provider = "custom" 标识，目的是不主动创建新的历史 bucket。快照文件放在应用自己的 snapshots/ 子目录，manifest 记录当前模式、最近 GPT 快照、事务阶段和最近一次验证结果。验证结果只记录 provider、模型和无密钥的状态消息，不记录 API Key。

API Key 只通过 Keychain 在运行时读取，并在启动 ChatGPT 时放入子进程环境。它不进入 TOML、参数、包装器脚本、通知、日志、快照或错误类型。

## 命令行 intent 和包装器

主 executable 支持：

- 无参数：交互式窗口和菜单栏；
- --mode=deepseek：执行一次 DeepSeek 切换；
- --mode=gpt：执行一次 GPT 恢复；
- --check：执行一次预检；
- --codex-home <path> 和 --chatgpt-app <path>：为测试和其他用户注入路径。

桌面包装器只保存模式参数。包装器优先寻找 staging 目录旁的主 app，安装后再寻找当前用户 Applications 目录中的主 app，因此不会把凭据复制进桌面文件。

## 可移植性边界

代码使用 FileManager.homeDirectoryForCurrentUser、应用支持目录和参数注入，不嵌入某个用户的个人路径。/Users/mac 只可能作为本次开发环境或文档中的部署示例，不是运行时常量。不同 macOS 用户、ChatGPT 安装位置、客户端 bundle identifier 或 Codex 配置版本可能需要通过参数或后续适配支持。
