# DeepSeek Model Guard Design

**Date:** 2026-08-11
**Status:** Approved design; implementation pending

## Goal

在 DeepSeek provider 模式下，让 `Codex Provider Switcher` 常驻 macOS 菜单栏并监视 Codex 的 `config.toml`。如果 ChatGPT 右下角的模型选择器把根配置中的 DeepSeek 模型改成 GPT 模型，工具应自动恢复为当前 DeepSeek 配置的模型，避免继续产生“DeepSeek endpoint + GPT model”混合状态。

## Context and root cause

当前配置使用两层信息：

- `model_provider = "custom"` 表示使用自定义 provider；
- 根级 `model = "deepseek-v4-flash"` 表示发送请求时选择的模型。

ChatGPT 的模型选择器可以改写根级 `model`，但不会同步把自定义 provider 恢复为 GPT provider。于是可能出现 DeepSeek endpoint、DeepSeek wire API、DeepSeek 鉴权方式仍在生效，但模型名变成 `gpt-*` 的混合配置。这个状态不能被可靠地当作正常 GPT 或正常 DeepSeek 使用。

切换器不拥有 ChatGPT 的私有模型选择器 UI，因此不能安全地把下拉菜单置灰或隐藏。方案采用配置层守护：尽快修复本地配置，同时明确记录无法撤销已经发出的错误请求或已经被客户端缓存的会话模型选择。

## Design decisions

### 1. 只修复明确识别为 DeepSeek 的配置

守护器仅在以下条件同时满足时写入：

- `CodexConfigTransformer.detectMode(in:settings:) == .deepSeek`；
- 根级 `model` 与 `DeepSeekSettings.model` 不一致。

GPT 配置和无法识别的配置绝不由守护器修改。修复时只改变根级 `model` assignment，保留 provider 表、其他根级配置、注释、空行和换行格式。

### 2. 复用事务锁并使用原子替换

模型修复通过 `SwitchTransactionCoordinator` 暴露的窄接口执行，并复用 `switch.lock.v2`。守护器观察到锁被切换事务持有时跳过本次事件，并安排一次有界的延迟重扫，同时继续等待下一次配置文件变化；它不会把正常的切换过程报告为失败，也不会绕过锁直接写文件。

修复继续使用 `ConfigSnapshotStoring.atomicallyReplace`，不打开、不更新、不迁移 `state_5.sqlite`、WAL/SHM 文件、会话 JSONL 或历史线程表。成功修复后会使旧 provider 验证状态失效，下一次状态读取重新验证当前模型。

### 3. 常驻生命周期

- 无参数启动的交互式主程序启动守护器，并在退出时停止守护器。
- `--mode=deepseek` 和 `--mode=gpt` 的桌面快捷方式执行切换后不立即退出，而是进入常驻菜单栏状态；这样从快捷方式切到 DeepSeek 后也具备实时保护。
- `--check` 仍是一次性操作，完成后退出，不启动守护器。
- 常驻状态提供退出入口；退出守护器不会改变当前 provider 配置。

配置监视使用配置文件所在目录的文件系统事件，而不是固定时间循环。由于原子替换会更换文件 inode，监视父目录并在事件后重新读取配置，避免只监视旧文件描述符。事件处理做短暂去抖，并保证同一时间最多一个修复任务。

### 4. 用户可见反馈

菜单栏和主窗口显示守护器状态：未启动、正在监视、最近一次自动恢复或监视错误。自动恢复消息包含目标模型名，但不包含 API Key、完整配置内容或会话文本。

说明文字明确：守护器保护的是本地 provider 配置；如果错误模型已经被 ChatGPT 缓存在会话内或请求已经发送，工具不能撤回服务端请求。此时应切回 GPT 后新建 GPT 线程，或手动复制文字摘要继续。

## Components and interfaces

### `Config/CodexConfigTransformer.swift`

新增窄范围模型修复接口：

```swift
func repairDeepSeekModel(
    in text: String,
    settings: DeepSeekSettings
) throws -> String?
```

返回 `nil` 表示配置不是 DeepSeek 或模型已经正确；返回新的完整文本表示只修复了根级 `model`。方法不得写文件、读取钥匙串或改变其他 provider 字段。

### `Switch/SwitchTransactionCoordinator.swift`

新增：

```swift
enum DeepSeekModelGuardResult: Equatable, Sendable {
    case ignored
    case repaired(model: String)
}

func repairDeepSeekModelIfNeeded() async throws -> DeepSeekModelGuardResult
```

该方法负责取得/释放事务锁、读取配置、调用 transformer、原子写回并清除与旧模型关联的验证状态。锁竞争按可恢复的“本次忽略”处理，不能把普通切换显示成错误。

### `Process/ConfigFileMonitor.swift`

新增可注入的目录事件监视器和 `DeepSeekModelGuard`：

- `start()` 建立父目录文件描述符和事件源；
- 事件发生后去抖并调用 coordinator 的修复接口；
- `stop()` 取消事件源、关闭文件描述符并取消挂起任务；
- 通过回调把 `repaired`、`ignored` 和不可恢复错误交给 `AppModel`；
- 不在监视器内部直接写配置，保持文件访问和事务锁集中在 coordinator。

### App/UI and packaging

`AppModel` 持有守护器生命周期和可见状态。交互式启动时自动启动；一次性 mode runner 在切换完成后转入常驻状态。`MenuBarExtra` 增加守护状态文本和退出入口；主窗口增加当前守护状态和最近修复提示。

打包脚本的快捷方式仍只传递 mode 参数，不携带 API Key；主 executable 的一次性 mode 行为改为“切换完成后进入常驻守护”，`--check` 保持一次性。

## Data flow

```text
ChatGPT model picker
        │ writes root model in config.toml
        ▼
parent-directory file event
        ▼
debounced DeepSeekModelGuard
        ▼
SwitchTransactionCoordinator.acquire(switch.lock.v2)
        ▼
read/classify config → repair root model if needed
        ▼
atomic replace config.toml → invalidate stale verification
        ▼
publish visible “已恢复 DeepSeek 模型” status
```

切换事务和模型守护共享同一把锁；两者都不写历史数据库或会话文件。

## Error handling

- 配置不存在、无法解析或 provider 未知：报告监视错误/忽略，不写文件；下次文件事件继续尝试。
- 当前是 GPT：忽略，绝不把 GPT 模型改成 DeepSeek。
- 锁被占用：跳过当前事件，安排有界延迟重扫，并等待下一次事件或显式刷新。
- 原子替换失败：保留原文件，显示修复失败，不删除快照。
- 监视器启动失败：显示“守护未启动”，切换器仍可作为普通手动切换工具运行。
- 守护器退出：不修改 provider，不删除快照，不清理历史。

## Testing strategy

### Unit tests

- DeepSeek 配置中 `model = "gpt-..."` 被修复为 `deepseek-v4-flash`，并保留无关配置、注释和换行。
- 已经是 DeepSeek 模型时返回 `nil`，不产生写入。
- GPT 配置和未知 provider 不被修复。
- coordinator 在真实的测试锁下执行修复；锁竞争不会写配置。
- 修复后 manifest 不继续报告旧模型的验证结果。
- `DeepSeekModelGuard` start/stop 可重复调用，事件不会并发触发多个修复任务。
- 一次性 mode runner 在切换成功后保持守护，`--check` 仍然退出。

### Verification

- `swift test` 全量通过；
- `swift build -c release --product CodexProviderSwitcher` 通过；
- `scripts/package-app.sh`、plist 校验和 ad-hoc codesign 通过；
- 在临时 Codex home 中模拟 DeepSeek 配置被改为 GPT 模型，确认守护器只改变 model 字段；
- 对真实用户环境只做读状态检查，除非用户明确触发切换，不自动改写真实配置。

## Non-goals and limitations

- 不修改或注入 ChatGPT 私有 UI，不承诺隐藏/禁用原生模型菜单；
- 不把 `model` 写成 `custom`，因为 `custom` 是 provider ID，不是可请求的模型；
- 不迁移、清理或重写历史线程；
- 不保证已被客户端缓存或已经发送的错误模型请求可以恢复；
- 不新增常驻 LaunchAgent，守护生命周期由切换器应用本身负责。
