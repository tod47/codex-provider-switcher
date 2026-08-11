# DeepSeek Model Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 DeepSeek provider 模式下常驻菜单栏监视 `config.toml`，自动把被 ChatGPT 改成 GPT 的根级模型恢复为 DeepSeek 模型，并保持切换事务、UI 和历史数据边界安全。

**Architecture:** 在现有 `CodexConfigTransformer` 增加纯文本模型修复函数，在 `SwitchTransactionCoordinator` 增加复用 `switch.lock.v2` 的原子修复入口。新增父目录文件系统事件监视器和去抖守护器；交互式启动和桌面 mode runner 都启动守护器，`--check` 仍然一次性退出。守护器只修改当前明确识别为 DeepSeek 配置的根级 `model`，不会访问历史数据库或会话 JSONL。

**Tech Stack:** Swift 6.0、macOS 14、SwiftPM executable、SwiftUI/AppKit、Foundation `DispatchSource`、Darwin 文件描述符、XCTest。

## Global Constraints

- 平台最低版本保持 macOS 14；不新增第三方依赖。
- `model_provider = "custom"` 是 provider ID；DeepSeek 请求模型必须保持为 `DeepSeekSettings.model`，默认值为 `deepseek-v4-flash`。
- GPT 配置和未知 provider 绝不由守护器自动写入。
- 所有配置写入必须经过现有 `ConfigSnapshotStoring.atomicallyReplace`，并与 `switch.lock.v2` 共享锁。
- 不打开、不更新、不迁移 `state_5.sqlite`、WAL/SHM 文件、会话 JSONL、历史线程表或其他历史桶。
- API Key 不得进入 TOML、启动参数、桌面包装器、日志、状态消息或测试输出。
- ChatGPT 私有模型选择器不被注入、修改、隐藏或反编译；守护器只提供配置层纠正。
- 真实用户配置只允许在用户明确执行切换或测试时改变；自动化测试只使用临时 Codex home。

---

### Task 1: Add pure DeepSeek model normalization

**Files:**
- Modify: `Sources/CodexProviderSwitcher/Config/CodexConfigTransformer.swift`
- Test: `Tests/CodexProviderSwitcherTests/CodexConfigTransformerTests.swift`

**Interfaces:**
- Consumes: existing `ParsedConfig`, `detectMode(in:settings:)`, `DeepSeekSettings`.
- Produces: `CodexConfigTransformer.repairDeepSeekModel(in:settings:) -> String?`.

- [ ] **Step 1: Write the failing tests**

Add these tests to `CodexConfigTransformerTests`:

```swift
func testRepairDeepSeekModelRewritesOnlyRootModel() throws {
    let deepSeekConfig = try transformer.makeDeepSeekConfig(
        from: fixture,
        settings: deepSeekSettings
    )
    let corrupted = deepSeekConfig.replacingOccurrences(
        of: "model = \"deepseek-v4-flash\"",
        with: "model = \"gpt-5.6-terra\""
    )

    let repaired = try transformer.repairDeepSeekModel(
        in: corrupted,
        settings: deepSeekSettings
    )

    XCTAssertEqual(repaired, deepSeekConfig)
}

func testRepairDeepSeekModelReturnsNilWhenAlreadyCorrectOrNotDeepSeek() throws {
    let deepSeekConfig = try transformer.makeDeepSeekConfig(
        from: fixture,
        settings: deepSeekSettings
    )

    XCTAssertNil(try transformer.repairDeepSeekModel(
        in: deepSeekConfig,
        settings: deepSeekSettings
    ))
    XCTAssertNil(try transformer.repairDeepSeekModel(
        in: fixture,
        settings: deepSeekSettings
    ))
}
```

- [ ] **Step 2: Run the focused tests and verify the expected RED failure**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.CodexConfigTransformerTests
```

Expected: compilation fails because `CodexConfigTransformer` has no `repairDeepSeekModel` method. Do not alter production code before observing this failure.

- [ ] **Step 3: Implement the minimal transformer method**

Add `repairDeepSeekModel(in:settings:)` after `configuration(in:settings:)`:

```swift
func repairDeepSeekModel(
    in text: String,
    settings: DeepSeekSettings
) throws -> String? {
    var parsed = try ParsedConfig(text: text)
    guard detectMode(in: text, settings: settings) == .deepSeek,
          let modelAssignment = parsed.singleAssignment(table: nil, key: "model"),
          modelAssignment.value != settings.model
    else {
        return nil
    }

    parsed.lines[modelAssignment.lineIndex] = assignmentLine(
        key: "model",
        value: settings.model,
        originalLine: parsed.lines[modelAssignment.lineIndex]
    )
    return parsed.rendered()
}
```

The method must preserve the existing line ending and original indentation, and must not change provider-table assignments.

- [ ] **Step 4: Run the focused tests and the full baseline suite**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.CodexConfigTransformerTests
swift test
```

Expected: the two new tests and all existing tests pass with zero failures.

- [ ] **Step 5: Commit the isolated task**

```bash
git add Sources/CodexProviderSwitcher/Config/CodexConfigTransformer.swift Tests/CodexProviderSwitcherTests/CodexConfigTransformerTests.swift
git commit -m "feat: normalize DeepSeek model configuration"
```

### Task 2: Add lock-safe coordinator repair

**Files:**
- Modify: `Sources/CodexProviderSwitcher/Switch/SwitchTransactionCoordinator.swift`
- Modify: `Tests/CodexProviderSwitcherTests/SwitchTransactionCoordinatorTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**
- Consumes: `repairDeepSeekModel(in:settings:)`, `ConfigSnapshotStoring.atomicallyReplace`, `SwitchLocking`, `ManifestStore`.
- Produces:

```swift
enum DeepSeekModelGuardResult: Equatable, Sendable {
    case ignored
    case repaired(model: String)
}

func repairDeepSeekModelIfNeeded() async throws -> DeepSeekModelGuardResult
```

- [ ] **Step 1: Write the failing coordinator tests**

Add tests using the existing temporary `TestContext`:

```swift
func testRepairDeepSeekModelIfNeededRestoresWrongModelWithoutTouchingHistory() async throws {
    let context = try makeContext()
    _ = try await context.coordinator.switchTo(.deepSeek)
    let corrupted = try String(contentsOf: context.configURL)
        .replacingOccurrences(
            of: "model = \"deepseek-v4-flash\"",
            with: "model = \"gpt-5.6-terra\""
        )
    try corrupted.write(to: context.configURL, atomically: true, encoding: .utf8)

    let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

    XCTAssertEqual(result, .repaired(model: "deepseek-v4-flash"))
    XCTAssertTrue(try String(contentsOf: context.configURL).contains(
        "model = \"deepseek-v4-flash\""
    ))
    XCTAssertEqual(
        try Data(contentsOf: context.stateURL),
        Data("history sentinel".utf8)
    )
}

func testRepairDeepSeekModelIfNeededNeverChangesGPTConfiguration() async throws {
    let context = try makeContext()
    let original = try Data(contentsOf: context.configURL)

    let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

    XCTAssertEqual(result, .ignored)
    XCTAssertEqual(try Data(contentsOf: context.configURL), original)
}

func testRepairDeepSeekModelIfNeededIgnoresLockContention() async throws {
    let context = try makeContext()
    context.lock.acquireError = SwitchLockError.alreadyHeld

    let result = try await context.coordinator.repairDeepSeekModelIfNeeded()

    XCTAssertEqual(result, .ignored)
    XCTAssertEqual(context.lock.acquireCount, 1)
    XCTAssertEqual(context.lock.releaseCount, 0)
}
```

Add fixture setup that writes a DeepSeek configuration with a GPT model before calling the repair method, without changing the shared history sentinel.

- [ ] **Step 2: Run the focused tests and verify the expected RED failure**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SwitchTransactionCoordinatorTests
```

Expected: compilation fails because the result type and coordinator method do not exist.

- [ ] **Step 3: Implement the lock-safe coordinator method**

Add `DeepSeekModelGuardResult` near `SwitchResult` and add this method to `SwitchTransactionCoordinator`:

```swift
func repairDeepSeekModelIfNeeded() async throws -> DeepSeekModelGuardResult {
    do {
        try lock.acquire()
    } catch let error as SwitchLockError {
        if error == .alreadyHeld {
            return .ignored
        }
        throw SwitchError.lockFailed
    } catch {
        throw SwitchError.lockFailed
    }
    defer { lock.release() }

    let originalConfig = try readConfig()
    guard let repairedConfig = try transformer.repairDeepSeekModel(
        in: originalConfig,
        settings: settings.deepSeek
    ) else {
        return .ignored
    }

    do {
        try snapshotStore.atomicallyReplace(
            configURL: settings.codexConfigURL,
            with: repairedConfig
        )
    } catch {
        throw SwitchError.configurationWriteFailed
    }

    if var manifest = try? manifestStore.load() {
        manifest.lastVerification = nil
        try? manifestStore.save(manifest)
    }
    return .repaired(model: settings.deepSeek.model)
}
```

The repair path must not create a new snapshot, stop ChatGPT, launch ChatGPT, or read the API key. A lock collision is an expected no-op for a background watcher.

- [ ] **Step 4: Run coordinator tests and the full suite**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SwitchTransactionCoordinatorTests
swift test
```

Expected: all coordinator tests and the full suite pass with zero failures.

- [ ] **Step 5: Commit the isolated task**

```bash
git add Sources/CodexProviderSwitcher/Switch/SwitchTransactionCoordinator.swift Tests/CodexProviderSwitcherTests/SwitchTransactionCoordinatorTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: add lock-safe DeepSeek model repair"
```

### Task 3: Add config-directory watcher and debounced guard

**Files:**
- Create: `Sources/CodexProviderSwitcher/Process/ConfigFileMonitor.swift`
- Modify: `Sources/CodexProviderSwitcher/Switch/SwitchTransactionCoordinator.swift`
- Modify: `Tests/CodexProviderSwitcherTests/ConfigFileMonitorTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**
- Define the repair boundary used by the watcher:

```swift
protocol DeepSeekModelRepairing: Sendable {
    func repairDeepSeekModelIfNeeded() async throws -> DeepSeekModelGuardResult
}
```

- Define a filesystem watcher and main-actor guard:

```swift
protocol ConfigDirectoryWatching: AnyObject {
    func start(onChange: @escaping @Sendable () -> Void) throws
    func stop()
}

enum DeepSeekModelGuardState: Equatable, Sendable {
    case stopped
    case monitoring
    case repaired(model: String)
    case failed(String)
}

@MainActor
final class DeepSeekModelGuard {
    init(
        watcher: any ConfigDirectoryWatching,
        repairer: any DeepSeekModelRepairing,
        debounceNanoseconds: UInt64 = 250_000_000,
        onStateChange: ((DeepSeekModelGuardState) -> Void)? = nil
    )

    var state: DeepSeekModelGuardState { get }
    func start()
    func stop()
}
```

- [ ] **Step 1: Write the failing watcher and guard tests**

Add test doubles for a manually triggered watcher and an actor-safe repairer. Cover these cases:

```swift
func testGuardStartPerformsInitialRepairAndPublishesState() async throws
func testGuardCoalescesMultipleFilesystemEventsIntoOneRepair() async throws
func testGuardStopAndRestartAreIdempotent() async throws
```

The tests must assert that the callback is installed once, a burst of events results in one debounced repair, and stopping prevents later callbacks from scheduling work. Do not use the real filesystem watcher in unit tests.

- [ ] **Step 2: Run the focused tests and verify the expected RED failure**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.ConfigFileMonitorTests
```

Expected: compilation fails because the watcher, guard state, and repairer protocol do not exist.

- [ ] **Step 3: Implement the real watcher and bounded guard**

Implement `ConfigDirectoryWatcher` with a Darwin `O_EVTONLY` descriptor for the parent directory of `config.toml` and a `DispatchSourceFileSystemObject` listening for `.write`, `.rename`, and `.delete`. The cancel handler closes the descriptor, and repeated `start()`/`stop()` calls are safe.

Implement `DeepSeekModelGuard` on `@MainActor`: start the watcher, publish `.monitoring`, perform an initial repair, coalesce events with a 250 ms debounce, and retry a lock collision only a bounded number of times with an increasing delay. `.repaired(model:)` is a transient success state that returns to `.monitoring`; unexpected errors publish `.failed(String)`. The guard must never poll indefinitely or touch history files.

Make `SwitchTransactionCoordinator` conform to `DeepSeekModelRepairing` without changing its existing public switching behavior.

- [ ] **Step 4: Run guard tests and the full suite**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.ConfigFileMonitorTests
swift test
```

Expected: all guard tests and the full suite pass with zero failures.

- [ ] **Step 5: Commit the isolated task**

```bash
git add Sources/CodexProviderSwitcher/Process/ConfigFileMonitor.swift Sources/CodexProviderSwitcher/Switch/SwitchTransactionCoordinator.swift Tests/CodexProviderSwitcherTests/ConfigFileMonitorTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: watch DeepSeek model configuration"
```

### Task 4: Keep the guard resident in the menu-bar application

**Files:**
- Modify: `Sources/CodexProviderSwitcher/App/AppModel.swift`
- Modify: `Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift`
- Modify: `Sources/CodexProviderSwitcher/App/MainView.swift`
- Modify: `Tests/CodexProviderSwitcherTests/AppModelTests.swift`

**Interfaces:**
- Add an injectable guard boundary for UI tests:

```swift
@MainActor
protocol DeepSeekModelGuarding: AnyObject {
    var state: DeepSeekModelGuardState { get }
    var onStateChange: ((DeepSeekModelGuardState) -> Void)? { get set }
    func start()
    func stop()
}
```

- [ ] **Step 1: Write the failing app-model tests**

Add a fake `DeepSeekModelGuarding` and tests that assert `AppModel` starts it for interactive mode, exposes its state to the view, and stops it when the model is torn down. Assert that a `.repaired(model:)` state produces a concise user-visible status message without exposing secrets.

- [ ] **Step 2: Run the focused tests and verify the expected RED failure**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.AppModelTests
```

Expected: compilation fails because `AppModel` has no guard dependency or published guard state.

- [ ] **Step 3: Implement resident interactive and mode-runner behavior**

Inject the guard into `AppModel`, publish `modelGuardState`, and bind the guard callback to status updates. Start it when the interactive application is created and stop it on teardown. The main window and menu-bar extra show whether the guard is monitoring, repairing, or failed.

Update `CodexProviderSwitcherApp` so interactive launch and `--mode` launches remain resident after the provider operation completes. Keep `--check` one-shot and terminating. The resident mode runner uses accessory activation policy and the existing menu-bar UI; it must not open a private ChatGPT UI or alter ChatGPT internals. Starting a mode operation must start the guard after the transaction succeeds, and a failed transaction must not leave a background guard running.

Update `MainView` with a clear explanation that the guard restores the DeepSeek model if ChatGPT's picker changes the root model, while the provider remains DeepSeek. Include a recovery action that invokes the existing provider verification; do not add a history repair or database migration action.

- [ ] **Step 4: Run app-model tests and the full suite**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.AppModelTests
swift test
```

Expected: all app-model tests and the full suite pass with zero failures.

- [ ] **Step 5: Commit the isolated task**

```bash
git add Sources/CodexProviderSwitcher/App/AppModel.swift Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift Sources/CodexProviderSwitcher/App/MainView.swift Tests/CodexProviderSwitcherTests/AppModelTests.swift
git commit -m "feat: keep DeepSeek guard resident"
```

### Task 5: Document and package the feature

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/usage.md`
- Modify: `docs/release-checklist.md`

- [ ] **Step 1: Document the supported workflow**

Document the resident menu-bar behavior, the difference between provider ID `custom` and model name, the automatic repair scope, `--check` one-shot behavior, bounded lock retry, and the fact that no history database/session JSONL is read or changed. State the limitation that an already-submitted or server-cached request cannot be rewritten by the local guard.

- [ ] **Step 2: Run documentation and packaging checks**

Run:

```bash
git diff --check
swift build -c release
staging_dir="$(mktemp -d /tmp/codex-provider-switcher-guard.XXXXXX)"
bash scripts/package-app.sh "$staging_dir"
for bundle in "$staging_dir"/*.app; do
  /usr/bin/plutil -lint "$bundle/Contents/Info.plist"
  /usr/bin/codesign --verify --deep --strict "$bundle"
done
```

Expected: no whitespace errors, the release build succeeds, every staged app has a valid property list, and code-signature verification succeeds.

- [ ] **Step 3: Commit the documentation update**

```bash
git add README.md docs/architecture.md docs/usage.md docs/release-checklist.md
git commit -m "docs: explain DeepSeek model guard"
```

### Task 6: Final verification and local handoff

- [ ] **Step 1: Run the complete verification set**

Run:

```bash
swift test
swift build -c release
git diff --check
git status --short --branch
```

Also inspect the final diff for accidental API keys, history-file access, private UI changes, or writes outside the requested configuration path.

- [ ] **Step 2: Install the verified local app**

After all tests and package checks pass, stage the release app and run the existing desktop launcher installer so the current local app uses the verified build. Do not install or modify a real user Codex configuration during verification; only the app bundle and launcher are updated.

- [ ] **Step 3: Report evidence and integration state**

Report the exact test/build/package checks, the installed app location, the branch and commits, and whether the branch was pushed. Keep the branch local unless the user explicitly asks to push it.
