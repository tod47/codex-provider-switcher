# Security

这是一个本地配置切换工具。它会读取和原子替换当前用户的 Codex config.toml，并请求退出、重新启动 ChatGPT；它不应修改 Codex 历史数据库、会话文件或线程记录。

## 使用和诊断时的注意事项

- 不要把 API Key、Keychain 导出、Cookie、完整 config.toml、auth.json、SQLite 文件、WAL/SHM 文件或会话 JSONL 上传到 Issue、聊天或公共仓库。
- 分享诊断前，删除用户名、绝对路径、组织信息、模型请求内容和任何 token；保留脱敏后的错误类型和事务阶段即可。
- 先使用应用生成的配置快照，再进行人工恢复或排障。
- DeepSeek provider 是实验性接入；预检通过不代表真实 Responses 请求、工具调用、流式事件或旧会话恢复一定兼容。
- 安装脚本只应覆盖 bundle identifier 为 local.codex.provider-switcher 的目标；遇到其他应用应停止。

## 报告问题

如果问题可能导致密钥泄露、配置被错误覆盖或历史数据被修改，请不要公开发布原始诊断。先私下联系维护者；在项目正式发布前，请补充专门的安全联系方式和处理流程。

报告中应提供：

- 脱敏后的复现步骤；
- macOS 和 Swift 版本；
- 使用的是临时 Codex home 还是本机配置；
- swift test 的结果；
- 不包含密钥和个人历史的最小日志。

