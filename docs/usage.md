# 使用说明

## 日常使用

打开 `Codex Provider Switcher.app` 后，主窗口会显示当前 provider、配置模型、endpoint、Codex 进程和验证状态。菜单栏图标会一直保留，方便在继续使用 ChatGPT/Codex 时执行切换或查看守护状态。

切到 DeepSeek 时，工具会先预检 endpoint 和钥匙串凭据，保存完整 GPT 配置快照，优雅退出 ChatGPT，原子替换 `config.toml`，再带着临时进程环境启动 ChatGPT。切回 GPT 时会恢复最近一次 GPT 快照。两条路径都不会打开或迁移历史数据库、WAL/SHM、会话 JSONL 或历史桶。

## 防止误改模型

DeepSeek 模式下请把右下角的客户端模型列表看作界面选择器，而不是 provider 状态来源。配置中的：

- `model_provider = "custom"` 表示使用名为 `custom` 的 provider 表；
- `[model_providers.custom]` 中的 endpoint 和协议字段决定它是否是 DeepSeek；
- 根级 `model = "deepseek-v4-flash"` 决定发送给 DeepSeek 的模型。

常驻守护器发现 provider 仍是 DeepSeek、但根级模型被改成 GPT 模型时，会在后台取得切换锁并只修复根级 `model`。它保留其他 TOML 内容和行格式，不创建新的历史记录，也不写 API Key。修复后旧的 provider 验证状态会被清除，避免显示过期的模型结果。

如果切换事务正在进行，守护器会暂时跳过本次事件，并做有限次数重试；不会无限占用 CPU 或反复写配置。状态显示“修复失败”时，可以先在工具中点击“仅检查”确认 endpoint，再点击“测试当前请求”确认实际响应模型。

## 命令行和桌面快捷方式

```text
.build/release/CodexProviderSwitcher --mode=deepseek
.build/release/CodexProviderSwitcher --mode=gpt
.build/release/CodexProviderSwitcher --check
```

`--mode=deepseek` 和 `--mode=gpt` 在操作完成后保持菜单栏常驻，因此从终端调用不会立即让守护器消失。`--check` 只做预检并在提示结果后退出。桌面上的两个 `.app` 包装器只传递模式参数，不包含 API Key。

## 已知边界

模型守护器只能修复尚未提交的新请求所使用的本地 `config.toml`。它不能撤回已经发出的请求，不能修改服务端响应，也不能重写 ChatGPT/Codex 已经缓存的会话模型状态。若某个已经打开的对话仍然报错，应先保存需要的内容，再用菜单栏切回 GPT 或重新切到 DeepSeek，让主程序按新的 provider 配置重启。

真实切换仍须由用户明确点击或运行命令行 intent；自动守护只做 DeepSeek 模型配置的窄范围纠正，不执行历史恢复、数据库迁移或私有 UI 注入。
