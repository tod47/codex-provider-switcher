# Contributing

感谢参与。这个项目会修改本机 Codex 的 provider 配置，因此贡献时要优先保证可回滚、可审计和不泄露个人数据。

## 开发约定

- 使用 Swift 6 和 macOS 14+ SDK。
- 提交前运行 swift test；涉及打包时再运行 bash scripts/package-app.sh 做 staging 验证。
- 测试必须使用临时目录、临时 Codex home、假的进程控制器和假的网络探针。
- 不要在测试、示例、Issue、Pull Request 或截图中放入真实 API Key、Cookie、账号信息、完整配置文件或个人历史路径。
- 不要让代码写入 state_5.sqlite、WAL/SHM 文件、会话 JSONL、历史线程表或任何数据库迁移。
- 不要把 API Key 放进 TOML、命令行参数、AppleScript、桌面包装器、通知、日志或错误文案。
- 修改事务顺序、快照格式、Keychain 逻辑或安装脚本时，请同时补充失败路径测试。

## 提交前检查

至少完成：

    swift test
    swift build -c debug
    bash -n scripts/package-app.sh
    bash -n scripts/install-desktop-launchers.sh

如果使用真实本机做手工检查，请先备份配置，并在提交前清理 staging 产物、日志和本地快照。不要把 .env、auth.json、SQLite 文件或个人 Codex 目录复制进仓库。

## Pull Request 内容

说明变更的安全边界、回滚行为和测试方法。涉及 provider 兼容性的改动要明确标注“实验性”，不能把本地验证描述成 OpenAI 官方支持。

