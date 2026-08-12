# Release checklist

## Source and scope

- [ ] `LICENSE` 为 MIT License，README 与项目行为保持一致。
- [ ] 应用主窗口底部显示“由vibe睦头人制作”，README 不额外添加署名。
- [ ] 应用图标来自发布者提供的蓝白双模型切换图，并嵌入三个 app bundle。
- [ ] 没有把 API Key 写入 TOML、命令行包装器、日志、快照或状态消息。
- [ ] 守护器只修改当前 Codex `config.toml` 的根级模型，不读取历史数据库、WAL/SHM、会话 JSONL 或其他历史桶。
- [ ] provider ID `custom` 与模型名的说明已写入 README 和使用文档。
- [ ] ChatGPT 私有 UI 没有被注入、修改、隐藏或反编译。

## Behavior

- [ ] 交互式 app 启动后菜单栏守护器常驻。
- [ ] `--mode=deepseek` 成功后保持菜单栏常驻并启动守护器。
- [ ] `--mode=gpt` 成功后保持菜单栏常驻且不修改 GPT 配置。
- [ ] `--check` 仍为一次性操作并退出。
- [ ] DeepSeek provider 仍匹配但根级模型被改动时，只恢复目标模型。
- [ ] GPT、未知 provider、锁冲突和守护器停止时不会产生越界写入。
- [ ] 修复后旧的 provider 验证状态不会继续冒充当前模型验证。

## Verification

- [ ] `swift test`
- [ ] `swift build -c release`
- [ ] 临时 staging 目录中三个 app bundle 的 `Info.plist` 通过 `plutil -lint`。
- [ ] 三个 app bundle 通过 `/usr/bin/codesign --verify --deep --strict`。
- [ ] `.dmg` 和 `.zip` 都包含主应用与两个桌面快捷方式，且不包含 API Key、个人配置或历史文件。
- [ ] `git diff --check`。
- [ ] 手工确认桌面快捷方式未携带 API Key，且目标 bundle identifier 冲突保护仍有效。

## Handoff

- [ ] 记录分支、提交、测试结果和打包产物位置。
- [ ] 未经明确授权不推送远端；如果要开源发布，再单独创建 PR 或推送到 GitHub。
