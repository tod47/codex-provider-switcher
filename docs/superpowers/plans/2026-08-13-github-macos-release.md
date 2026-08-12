# GitHub macOS Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将当前 provider switcher 分支发布为带应用署名、定制图标和 DMG/ZIP 下载资产的 macOS `v0.2.0` GitHub Release。

**Architecture:** SwiftUI 主窗口只增加底部署名；发布脚本使用 `sips` 和 `iconutil` 生成 `.icns`，将图标和版本号写入三个 app bundle，并用同一组 bundle 生成 ZIP 和带 Applications 别名的 DMG。GitHub 发布使用当前分支、已有 `tod47/codex-provider-switcher` 仓库和 `v0.2.0` Release。

**Tech Stack:** Swift 6.0、SwiftUI、macOS 14、Bash、`sips`、`iconutil`、`hdiutil`、`zip`、ad-hoc `codesign`、GitHub CLI/connector。

## Global Constraints

- 应用主窗口底部显示 `由vibe睦头人制作`，README 不增加署名。
- 用户提供的 PNG 是唯一应用图标来源；图标嵌入主应用和两个快捷方式 bundle。
- 发布版本固定为 `0.2.0`。
- DMG 和 ZIP 只包含应用 bundle、快捷方式和安装所需的 Applications 别名，不包含个人配置、历史文件、API Key 或临时快照。
- 不运行完整单元测试，不执行真实 provider 切换；只运行 release 构建、脚本语法和发布产物检查。
- 不修改主工作树或其无关任务；只提交当前 `codex/provider-switcher` 分支范围内的文件。
- 远端仓库为 `tod47/codex-provider-switcher`，默认分支为 `main`，发布分支为当前 `codex/provider-switcher`。

---

### Task 1: Add application credit and icon asset

**Files:**
- Modify: `Sources/CodexProviderSwitcher/App/MainView.swift`
- Create: `Resources/CodexProviderSwitcher.icns`
- Modify: `scripts/make-app-icon.sh`
- Modify: `docs/release-checklist.md`

- [ ] **Step 1: Add the bottom credit**

Add a centered, tertiary-colored SwiftUI `Text` after the existing warning label and before the outer `VStack` closes:

```swift
Text("由vibe睦头人制作")
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity, alignment: .center)
```

Do not add this credit to README or command-line output.

- [ ] **Step 2: Generate the `.icns` resource**

Use the supplied image path as the source and run:

```bash
bash scripts/make-app-icon.sh \
  "/Users/mac/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_utdqvcbe540a22_2bf2/temp/RWTemp/2026-08/b4162fc72f5b75063fca969af63f50f7/1ae071ebd34d7ab9f97c148777a63c6b.png" \
  Resources/CodexProviderSwitcher.icns
file Resources/CodexProviderSwitcher.icns
```

Expected: `file` reports a Mac OS X icon and the resource exists under `Resources/`.

- [ ] **Step 3: Commit the UI and icon resource**

```bash
git add Sources/CodexProviderSwitcher/App/MainView.swift Resources/CodexProviderSwitcher.icns scripts/make-app-icon.sh docs/release-checklist.md
git diff --cached --check
git commit -m "feat: add branded macOS app identity"
```

### Task 2: Generate versioned macOS packages

**Files:**
- Modify: `scripts/package-app.sh`
- Modify: `docs/release-checklist.md`

- [ ] **Step 1: Update bundle metadata and package outputs**

The package script must accept `<staging-directory> [version]`, default to `0.2.0`, embed `Resources/CodexProviderSwitcher.icns`, write `CFBundleIconFile = CodexProviderSwitcher`, and generate:

```text
Codex-Provider-Switcher-0.2.0.dmg
Codex-Provider-Switcher-0.2.0.zip
```

The DMG staging directory must contain the three apps plus a symlink named `Applications` pointing to `/Applications`. The ZIP must contain a directory named `Codex-Provider-Switcher-0.2.0` with the same three apps.

- [ ] **Step 2: Validate shell syntax without building**

Run:

```bash
bash -n scripts/make-app-icon.sh
bash -n scripts/package-app.sh
bash -n scripts/install-desktop-launchers.sh
git diff --check
```

Expected: all commands exit zero. Do not run `swift test`.

- [ ] **Step 3: Commit the packaging changes**

```bash
git add scripts/package-app.sh scripts/make-app-icon.sh
git diff --cached --check
git commit -m "feat: package downloadable macOS release assets"
```

### Task 3: Build and inspect release assets

**Files:**
- No source changes expected; generated assets remain outside the repository in a temporary staging directory.

- [ ] **Step 1: Build and package the release**

Run:

```bash
staging_dir="$(mktemp -d /tmp/codex-provider-switcher-release.XXXXXX)"
bash scripts/package-app.sh "$staging_dir" 0.2.0
```

This is the only Swift build in this release flow; do not run `swift test`.

- [ ] **Step 2: Inspect app metadata, icon, signatures, and archive contents**

Run:

```bash
for bundle in "$staging_dir"/*.app; do
  /usr/bin/plutil -lint "$bundle/Contents/Info.plist"
  /usr/bin/codesign --verify --deep --strict "$bundle"
  test -f "$bundle/Contents/Resources/CodexProviderSwitcher.icns"
  /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist"
done

/usr/bin/hdiutil imageinfo "$staging_dir/Codex-Provider-Switcher-0.2.0.dmg" >/dev/null
/usr/bin/unzip -l "$staging_dir/Codex-Provider-Switcher-0.2.0.zip"
```

Confirm the archives contain only the three app bundles and expected installation alias, with no `.codex`, `config.toml`, `state_5.sqlite`, API Key text, or personal home-directory paths.

- [ ] **Step 3: Install only after package inspection**

Run the existing installer against the inspected staging directory:

```bash
bash scripts/install-desktop-launchers.sh "$staging_dir"
```

This updates only the existing project bundle identifier targets under `~/Applications` and `~/Desktop`.

### Task 4: Push and publish GitHub Release

**Files:**
- No further local source changes expected.

- [ ] **Step 1: Review scope and commit the final changes**

Run:

```bash
git status --short --branch
git diff main...HEAD --stat
git log --oneline main..HEAD
```

Stage only the release work and preserve the pre-existing untracked `docs/superpowers/plans/2026-08-10-verified-provider-switching.md` file. Confirm no README-only attribution change is present.

- [ ] **Step 2: Push the current branch**

Run:

```bash
git remote add origin https://github.com/tod47/codex-provider-switcher.git  # only if origin is absent
git push -u origin codex/provider-switcher
```

- [ ] **Step 3: Create the release and upload assets**

Create release tag `v0.2.0` targeting the pushed `codex/provider-switcher` commit, with notes that explain the DeepSeek model guard, the bottom credit, the custom icon, the experimental status, macOS 14 requirement, ad-hoc signing, and the DMG/ZIP installation paths. Upload exactly:

```text
Codex-Provider-Switcher-0.2.0.dmg
Codex-Provider-Switcher-0.2.0.zip
```

- [ ] **Step 4: Report release evidence**

Report the branch, commit, tag, GitHub Release URL, asset URLs, local installed app paths, and the exact release-build/package checks. Explicitly state that full unit tests and real provider switching were not run by request.
