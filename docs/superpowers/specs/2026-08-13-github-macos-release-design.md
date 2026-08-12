# GitHub macOS Release Design

## Goal

将当前 `codex/provider-switcher` 分支发布为可供他人下载的 macOS 版本，并把现有应用整理成 GitHub Release 资产。发布范围包括应用底部署名、用户提供的应用图标、可安装的 `.dmg` 和便携 `.zip`，以及 GitHub 上的版本说明。

## Scope

- 在 SwiftUI 主窗口底部增加一行 `由vibe睦头人制作`。
- 不修改 README 来增加署名。
- 将用户提供的 PNG 转换为 macOS `.icns`，用于主应用和两个桌面快捷方式。
- 发布版本号更新为 `0.2.0`。
- 打包脚本继续生成主应用、DeepSeek 快捷方式和 GPT 快捷方式；额外生成：
  - `Codex-Provider-Switcher-0.2.0.dmg`
  - `Codex-Provider-Switcher-0.2.0.zip`
- DMG 提供主应用和两个快捷方式，另放一个 `Applications` 文件夹别名，便于拖拽安装。
- ZIP 包包含主应用和两个快捷方式，适合不使用 DMG 的用户。
- 推送当前功能分支到 `tod47/codex-provider-switcher`，创建 `v0.2.0` GitHub Release 并上传两个下载资产。

## Icon pipeline

资源脚本使用 `sips` 生成 macOS 所需的 16、32、128、256、512 和 1024 像素 PNG，再用 `iconutil` 组装 `CodexProviderSwitcher.icns`。原始图片只复制到临时构建目录，不进入应用运行时数据目录，也不包含任何用户密钥或配置。

## Packaging and safety

- `scripts/package-app.sh` 接收 staging 目录和可选版本参数；默认版本为 `0.2.0`。
- 打包前使用 release 配置构建，应用 bundle 的 `CFBundleShortVersionString` 和 `CFBundleVersion` 使用同一版本。
- 主应用、两个快捷方式和 DMG/ZIP 资产使用 ad-hoc code signing；不宣称 Apple notarization 或 Developer ID 签名。
- 打包脚本拒绝危险 staging 路径，安装脚本只替换既有 bundle identifier 为 `local.codex.provider-switcher` 的目标。
- 发布说明明确告知用户首次打开可能需要在 macOS 中右键“打开”，并说明实验性 DeepSeek provider 和本地配置/历史数据边界。
- 不执行完整单元测试；只执行 release 构建、脚本语法、plist、签名、DMG/ZIP 内容和 GitHub Release 资产存在性检查。

## GitHub flow

1. 将设计、UI、图标和打包脚本提交到当前分支。
2. 运行必要的 release 构建和产物检查。
3. 推送当前分支到远程 `origin`。
4. 创建或更新 `v0.2.0` Release，上传 `.dmg` 与 `.zip`。
5. 返回代码分支、提交、Release 地址和下载资产地址。

## Out of scope

- 不修改 README 增加作者署名。
- 不改变 DeepSeek 切换逻辑、历史恢复逻辑或 ChatGPT 私有 UI。
- 不运行真实 provider 切换。
- 不承诺 Apple Developer ID 签名、notarization 或自动更新。
