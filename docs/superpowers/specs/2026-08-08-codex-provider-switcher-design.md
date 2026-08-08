# Codex Provider Switcher 设计规格

日期：2026-08-08  
状态：方案一已选，待用户审阅  
目标：在 macOS 上通过桌面入口原地切换 ChatGPT/Codex 主程序的 provider，优先满足“继续查看并尝试续接既有任务”，同时保证配置可回滚、历史数据库不被改写。

## 1. 背景与边界

当前 ChatGPT 桌面端会启动本机 Codex app-server，并读取用户级 Codex 配置。当前主配置位于 `/Users/mac/.codex/config.toml`，历史数据库为 `/Users/mac/.codex/state_5.sqlite`。现有历史表中的 142 条任务均使用 `model_provider=custom`。

OpenAI 官方文档支持 Codex 本地客户端的自定义 provider、用户级配置、profile 和 `CODEX_HOME`；provider 的 `wire_api` 当前只支持 `responses`。官方文档没有承诺“在 ChatGPT 桌面端模型选择器中切换 DeepSeek”，所以本项目必须标记为本地实验性启动器，而不是官方 ChatGPT 第三方模型集成。

官方参考：

- https://learn.chatgpt.com/docs/config-file/config-reference
- https://learn.chatgpt.com/docs/config-file/config-advanced
- https://learn.chatgpt.com/docs/config-file/config-basic

本项目不做以下事情：

- 不使用或恢复 CC Switch；
- 不删除、重写、合并或迁移 `state_5.sqlite`、WAL、JSONL 会话文件；
- 不修改已有任务的 `model_provider` 字段；
- 不把 DeepSeek API Key 写入配置文件、命令行参数、桌面脚本或日志；
- 不承诺旧任务在 DeepSeek 上一定能够继续运行；
- 不修改 `chatgpt.com` 云端 ChatGPT 普通对话的模型列表。

用户已选择方案一：第一版直接在当前 `/Users/mac/.codex` 环境内切换 provider 配置并重启主 ChatGPT 程序。方案二（复制 `CODEX_HOME`）和方案三（独立 Codex CLI 入口）不纳入第一版实现。

## 2. 目标体验

安装后提供一个本地 macOS 小应用，并在桌面放置两个可选快捷入口：

- “切到 DeepSeek（重启 ChatGPT）”；
- “切回 GPT（重启 ChatGPT）”。

点击后应用执行以下事务：

1. 获取单实例锁，防止两个切换操作并发执行；
2. 检查 ChatGPT 是否正在运行；
3. 对当前配置做带时间戳的备份；
4. 请求 ChatGPT 正常退出，并等待主程序及 Codex app-server 完全结束；
5. 原子替换 provider 配置；
6. 启动 `/Applications/ChatGPT.app`；
7. 检查主程序启动状态并显示结果；
8. 如果替换或启动失败，自动恢复上一个配置并重启 GPT 模式。

切回 GPT 使用同一套流程，恢复切换前保存的完整 GPT 配置，而不是重新拼接若干字段。这样可以保留当前插件、权限、桌面设置和主 provider 配置，降低手工还原遗漏的风险。

## 3. 推荐实现方案

### 3.1 方案比较

| 方案 | 优点 | 主要限制 |
| --- | --- | --- |
| 原地切换 `/Users/mac/.codex/config.toml` | 主 ChatGPT 程序、任务列表和现有 provider 桶保持不变，最接近用户想要的体验 | 非官方桌面第三方 provider；旧任务是否能由 DeepSeek 续接需要实测；DeepSeek 请求协议必须兼容 |
| 复制到独立 `CODEX_HOME` 后启动 | GPT 主环境几乎不受影响，历史隔离最好 | ChatGPT 桌面端的 UI/状态可能不完全跟随独立 `CODEX_HOME`；复制后的历史是分支，不会自动与 GPT 环境同步 |
| 仅提供 Codex CLI profile | 属于官方文档描述的本地 CLI 配置方式，风险最低 | 不满足“重启主 ChatGPT 程序并继续原任务”的目标 |

采用第一种方案，并加入自动备份、失败回滚、协议预检和历史只读保护。第二种方案作为后续的“安全隔离模式”保留在比较记录中，但不作为第一版默认行为，也不在第一版实现。

### 3.2 provider 变更策略

为最大限度保留当前任务列表的可见性，第一版不把历史数据库中的 provider 从 `custom` 改成 `deepseek`，也不修改 thread 行。切换 DeepSeek 时只替换配置中以下内容：

- `model`；
- `model_providers.custom.name`；
- `model_providers.custom.base_url`；
- `model_providers.custom.env_key` 或对应认证设置；
- `model_providers.custom.requires_openai_auth`；
- 与 Responses 兼容性有关的 provider 开关。

切回 GPT 时恢复切换前保存的完整配置文件，而不是通过反向猜测字段恢复。

这种设计的含义是：

- 旧任务仍然属于原来的 `custom` 桶，历史数据库不被拆分；
- 切换后打开旧任务时，应用有机会把后续请求送往当前 DeepSeek endpoint；
- 但 Codex 可能按会话保存的模型、provider 或协议状态处理旧任务，所以“看到旧任务”和“能够由 DeepSeek 成功续接”不是同一件事；
- 如果续接失败，应用只显示错误，不修改该任务、不删除记录，用户可以切回 GPT 或新开 DeepSeek 会话。

### 3.3 DeepSeek endpoint 策略

Codex 配置参考要求 provider 使用 `wire_api = "responses"`。第一版不能把“普通 OpenAI-compatible Chat Completions endpoint”直接当成已兼容的 Codex endpoint。

启动 DeepSeek 模式前执行预检：

- 检查 base URL 是否存在；
- 检查是否配置了 DeepSeek 密钥；
- 优先检查本地 Responses 转换网关是否正在运行；
- 对网关做轻量连接检查；
- 如果仅发现普通 Chat Completions 配置，明确提示“协议未验证”，默认中止切换；
- 不自动把 API Key 打印到终端、通知、日志或错误窗口。

当前已有的 `/Users/mac/.codex/deepseek-v4.config.toml` 和桌面 `.command` 文件只作为迁移参考，第一版不会盲目信任其直连 endpoint。

## 4. 应用结构

### 4.1 macOS 应用

使用 SwiftUI 原生 macOS 应用，名称暂定为 `Codex Provider Switcher`。应用启动后提供一个简洁主窗口，同时注册菜单栏入口；应用本身不承担模型请求，只负责配置事务和生命周期管理。

主窗口保持单屏、低密度布局，包含：

- 当前模式卡片：GPT / DeepSeek / 未知；
- 两个主要按钮：“切到 DeepSeek并重启 ChatGPT”和“切回 GPT并重启 ChatGPT”；
- 一个次要按钮：“仅检查”；
- 最近一次切换时间、当前快照路径和失败原因；
- “打开备份目录”和“打开日志目录”；
- 实验性兼容性警告。

菜单栏入口提供同样的两个切换动作，方便用户不打开主窗口就一键切换。桌面上另放两个快捷应用，分别通过 `--mode=deepseek` 和 `--mode=gpt` 启动同一个切换核心。

UI、配置事务、进程控制和密钥存储必须保持独立接口，方便后续开源时让其他 macOS 用户通过自己的路径和网关设置使用，而不携带本机历史或账号信息。

### 4.2 本地数据目录

应用数据放在：

`~/Library/Application Support/Codex Provider Switcher/`

建议结构：

```text
Codex Provider Switcher/
├── manifest.json
├── locks/
├── snapshots/
│   ├── 20260808-...-before-deepseek/
│   │   ├── config.toml
│   │   └── manifest.json
│   └── ...
├── modes/
│   ├── gpt-config.toml
│   └── deepseek-config.toml
└── logs/
    └── switcher.log
```

配置快照只保存 provider 配置和恢复所需元数据。历史数据库不复制到每个切换快照，避免每次点击都制造 GB 级副本；历史数据库本身从不被本应用写入。

### 4.3 密钥处理

DeepSeek API Key 使用 macOS Keychain 保存，服务名固定为 `Codex Provider Switcher`，账户名固定为当前 macOS 用户。首次运行没有密钥时弹出安全输入框。

兼容现有 `.env` 仅作为一次性导入来源：读取后立即写入 Keychain，不在日志中显示，不在配置文件中落盘；用户可以选择不导入并手动输入。实现时不复制 `/Users/mac/.codex/.env` 到任何新目录。

因为 Codex provider 的 `env_key` 需要由进程环境提供密钥，启动 DeepSeek 模式时不能只用 Finder 的普通“打开应用”动作。切换器会从 Keychain 读取密钥，并通过受控的子进程环境传递给 ChatGPT/Codex app-server：

- API Key 不出现在命令行参数、AppleScript 文本、配置文件或日志中；
- 子进程退出后环境变量随之消失；
- 如果当前 macOS 启动路径无法安全注入环境变量，切换器在写入 DeepSeek 配置前中止并提示原因；
- GPT 模式不注入 DeepSeek 密钥，也不修改现有 ChatGPT 登录凭据。

## 5. 切换事务与回滚

### 5.1 正常切换

```text
点击快捷入口
    ↓
获取锁
    ↓
读取并识别当前模式
    ↓
检查目标 endpoint 和密钥
    ↓
请求 ChatGPT 正常退出
    ↓
等待 ChatGPT / Codex app-server 退出
    ↓
备份当前 config.toml
    ↓
生成并校验目标 config.toml.tmp
    ↓
原子替换 config.toml
    ↓
启动 ChatGPT.app
    ↓
等待启动并记录结果
    ↓
释放锁
```

### 5.2 失败回滚

以下情况都触发回滚：

- ChatGPT 无法在超时内退出；
- 目标配置生成或校验失败；
- 目标配置写入失败；
- ChatGPT 启动失败；
- 启动后发现配置文件内容不是目标模式。

回滚动作：

1. 关闭新启动但状态异常的 ChatGPT；
2. 用最近一次有效快照原子恢复配置；
3. 重新启动 GPT 模式；
4. 弹出失败原因和备份路径。

应用不使用强制删除、`git reset`、SQLite `DELETE` 或直接杀掉未知进程的方式恢复。

## 6. 兼容性与用户提示

DeepSeek 模式必须显示“实验性”标记，启动成功不等于模型协议完全兼容。以下能力可能不一致：

- 旧会话续接；
- 工具调用；
- 流式输出；
- 图片或文件输入；
- 推理摘要及 reasoning 字段；
- Web、浏览器和其他 Codex 内置工具；
- 会话中已经存在的 OpenAI 专用状态。

应用只保证：切换前配置有备份、历史数据库不被修改、切回 GPT 可以恢复切换前配置。它不保证 DeepSeek 能执行所有 Codex 能力，也不保证第三方 endpoint 的服务质量。

## 7. 可开源性与隐私边界

第一版不发布到 GitHub，也不在未选择许可证前添加开源许可证；但代码结构按可开源项目设计：

- Swift 源码、脚本、README 和测试中不写死 `/Users/mac`，运行时使用当前用户 home、命令行参数或用户设置；
- 仓库不包含 API Key、`auth.json`、`.env`、真实 `config.toml`、历史数据库、会话 JSONL、运行日志或快照；
- 测试使用临时目录、假进程控制器和本地 fixture，不启动真实 ChatGPT、不调用真实模型；
- README 说明实验性 provider 切换、Responses 兼容性、数据安全和回滚方式；
- 提供贡献说明和安全问题报告方式；
- 许可证作为后续明确决策，不由实现者擅自选择。

## 8. 验证计划

### 自动验证

- 配置生成测试：GPT → DeepSeek → GPT 往返后内容字节级一致；
- 敏感信息测试：API Key 不出现在配置、参数、日志和通知文本中；
- 原子写入测试：模拟中断时旧配置仍可恢复；
- 锁测试：两个切换请求不能并发修改配置；
- 模式识别测试：未知或人工改动配置时拒绝盲切换；
- 进程生命周期测试：正常退出、超时退出、启动失败和回滚；
- 历史保护测试：切换前后 `state_5.sqlite` 的完整性和任务数量不变。

### 本机验收

1. 先点“切回 GPT”，确认当前 GPT 配置和主程序正常；
2. 检查 142 条 `custom` 任务仍存在；
3. 点“仅检查”，确认 DeepSeek endpoint 和密钥预检结果；
4. 点“切到 DeepSeek”，确认主 ChatGPT 退出后重启；
5. 打开一个旧任务，记录是否能正常续接；
6. 新建一个极小的 DeepSeek 测试任务；
7. 点“切回 GPT”，确认主程序恢复并能继续原 GPT 任务；
8. 再次检查历史数据库完整性、任务数量和 JSONL 文件数量。

## 9. 明确的风险接受项

在实现前必须接受以下事实：

1. 这是本机实验性 provider 切换，不是 OpenAI 官方承诺的 ChatGPT 桌面功能；
2. DeepSeek endpoint 必须实际兼容 Codex 所需的 Responses 协议，否则切换器会拒绝启动或运行失败；
3. 旧任务是否能由 DeepSeek 续接需要在本机逐项验证；
4. ChatGPT 或 Codex 更新后可能改变 app-server、配置字段或状态行为，切换器需要重新验证；
5. 本项目不会把 DeepSeek 新产生的内容安全地合并回 GPT 的原始任务状态，也不会修改数据库来伪造这种合并。

如果这些边界可以接受，下一步再进入实现计划；实现前仍会先在临时配置和可回滚快照上测试。
