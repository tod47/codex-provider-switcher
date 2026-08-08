# Codex Provider Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar app with two desktop launchers that safely switch the current ChatGPT/Codex main program between the existing GPT provider and an experimental DeepSeek provider by backing up, atomically replacing, and restoring `/Users/mac/.codex/config.toml` without modifying Codex history databases.

**Architecture:** A SwiftPM macOS executable owns a transaction coordinator. The coordinator composes a config transformer, snapshot/manifest store, Keychain secret store, endpoint preflight, and ChatGPT process controller. The UI starts the coordinator, while two tiny wrapper app bundles pass `--mode=deepseek` or `--mode=gpt`; all model switching remains local and reversible.

**Tech Stack:** Swift 6 / SwiftPM, macOS 14+, SwiftUI `MenuBarExtra`, AppKit `NSRunningApplication` and `NSWorkspace`, Security Keychain APIs, Foundation/CryptoKit, XCTest, no third-party dependencies.

## Global Constraints

- The first version implements only the selected in-place-switch design; it does not implement a separate `CODEX_HOME` or CLI-only mode.
- The app must never modify `/Users/mac/.codex/state_5.sqlite`, its `-wal`/`-shm` companions, session JSONL files, or thread rows.
- The app must preserve the existing `model_provider = "custom"` identifier so the current history bucket is not deliberately split.
- The app must never put `DEEPSEEK_API_KEY` in a TOML file, command-line argument, AppleScript source, desktop wrapper, notification, or log.
- DeepSeek mode is experimental and requires `wire_api = "responses"`; the app must reject missing or invalid endpoint configuration before writing DeepSeek config.
- ChatGPT must be requested to quit gracefully and confirmed stopped before `config.toml` is replaced; the switcher must not force-kill unknown processes.
- Any write to `config.toml` must use a same-directory temporary file followed by an atomic replacement, with the prior config saved in a timestamped snapshot first.
- A failed switch must restore the last valid GPT configuration and relaunch ChatGPT in GPT mode.
- The live DeepSeek switch is not part of automated tests; tests use temporary Codex homes and fake process/network dependencies.
- No existing desktop launcher or `.env` file is deleted or overwritten during installation unless it is an app bundle created by this project and has the expected bundle identifier.

## File Map

Create the following files in `/Users/mac/Documents/日常杂活`:

```text
Package.swift
Sources/CodexProviderSwitcher/
├── App/CodexProviderSwitcherApp.swift
├── App/AppModel.swift
├── App/MainView.swift
├── Domain/ProviderMode.swift
├── Domain/SwitchSettings.swift
├── Config/CodexConfigTransformer.swift
├── Config/SnapshotStore.swift
├── Config/ManifestStore.swift
├── Security/SecretStore.swift
├── Security/KeychainSecretStore.swift
├── Security/EnvFileImporter.swift
├── Provider/EndpointPreflight.swift
├── Process/ChatGPTProcessController.swift
├── Process/ProcessTable.swift
├── Switch/SwitchTransactionCoordinator.swift
└── Support/Clock.swift
Tests/CodexProviderSwitcherTests/
├── DomainTests.swift
├── CodexConfigTransformerTests.swift
├── SnapshotStoreTests.swift
├── EnvFileImporterTests.swift
├── EndpointPreflightTests.swift
├── SwitchTransactionCoordinatorTests.swift
├── AppModelTests.swift
└── TestDoubles.swift
scripts/package-app.sh
scripts/install-desktop-launchers.sh
README.md
.gitignore
CONTRIBUTING.md
SECURITY.md
docs/architecture.md
```

Responsibilities are intentionally separated:

- `Domain`: Codable state and target-mode values with no filesystem or process side effects.
- `Config`: validate and transform only the provider-related TOML fields; save and restore complete configuration snapshots.
- `Security`: Keychain access and one-time `.env` import; never logs secrets.
- `Provider`: URL/model/protocol preflight without making a billable completion request.
- `Process`: inspect, gracefully quit, wait, and launch the ChatGPT bundle with a controlled environment.
- `Switch`: transaction ordering, lock, rollback, and manifest state.
- `App`: SwiftUI menu-bar presentation, first-run key prompt, alerts, and command-line launch intent.
- `scripts`: reproducible release build and safe creation of the main app plus the two desktop wrapper apps.

---

### Task 1: Create the SwiftPM macOS app skeleton

**Files:**

- Create: `Package.swift`
- Create: `Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift`
- Create: `Tests/CodexProviderSwitcherTests/DomainTests.swift`

**Interfaces:**

- Produces executable product `CodexProviderSwitcher`.
- Targets macOS 14 or later.
- Exposes a minimal `@main` SwiftUI app so later tasks can add menu-bar state without changing packaging.

- [ ] **Step 1: Write the package manifest and a compile smoke test**

Use this package shape:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexProviderSwitcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexProviderSwitcher", targets: ["CodexProviderSwitcher"])
    ],
    targets: [
        .executableTarget(name: "CodexProviderSwitcher"),
        .testTarget(
            name: "CodexProviderSwitcherTests",
            dependencies: ["CodexProviderSwitcher"]
        )
    ]
)
```

Add a test named `testPackageTargetIsLoadable()` that imports the executable module and asserts `true`; this establishes the test target before behavior is added.

- [ ] **Step 2: Run the new test to verify the skeleton fails only for missing app code**

Run:

```bash
swift test
```

Expected: the package resolves and the test target reports the missing executable module or app source if the skeleton has not yet been added.

- [ ] **Step 3: Add the minimal menu-bar app**

Implement:

```swift
import SwiftUI

@main
struct CodexProviderSwitcherApp: App {
    var body: some Scene {
        MenuBarExtra("Codex Provider Switcher", systemImage: "arrow.triangle.2.circlepath") {
            Text("Ready")
        }
    }
}
```

- [ ] **Step 4: Run the test and build the executable**

Run:

```bash
swift test
swift build -c debug
```

Expected: all tests pass and `.build/debug/CodexProviderSwitcher` exists.

- [ ] **Step 5: Commit the scaffold**

```bash
git add Package.swift Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift Tests/CodexProviderSwitcherTests/DomainTests.swift
git commit -m "feat: scaffold provider switcher mac app"
```

### Task 2: Define mode and settings domain types

**Files:**

- Create: `Sources/CodexProviderSwitcher/Domain/ProviderMode.swift`
- Create: `Sources/CodexProviderSwitcher/Domain/SwitchSettings.swift`
- Modify: `Tests/CodexProviderSwitcherTests/DomainTests.swift`

**Interfaces:**

```swift
enum ProviderMode: String, Codable, Equatable, Sendable {
    case gpt
    case deepSeek
    case unknown
}

struct DeepSeekSettings: Codable, Equatable, Sendable {
    let model: String
    let baseURL: URL
    let environmentKey: String
    let wireAPI: String
}

struct SwitchSettings: Codable, Equatable, Sendable {
    let codexHome: URL
    let codexConfigURL: URL
    let chatGPTApplicationURL: URL
    let deepSeek: DeepSeekSettings
    let keychainService: String
    let keychainAccount: String
    let quitTimeoutSeconds: Double
    let launchTimeoutSeconds: Double
}
```

- [ ] **Step 1: Write failing domain tests**

Add tests named:

```swift
func testProviderModeRoundTripsThroughCodable()
func testDefaultSettingsPointToTheCurrentCodexHomeAndChatGPTBundle()
func testDeepSeekSettingsRequireResponsesWireAPI()
```

The default settings test must use an injected home URL rather than the test runner's actual home directory.

- [ ] **Step 2: Run the focused tests and verify the types are missing**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.DomainTests
```

Expected: compilation failure naming the missing domain types.

- [ ] **Step 3: Implement the domain types and validation**

`DeepSeekSettings` must throw a typed `SwitchSettingsError.invalidWireAPI` when `wireAPI != "responses"`, and must reject an empty model, a URL without `http`/`https`, or an empty environment key. `ProviderMode` must remain `unknown` when the config cannot be classified rather than guessing GPT.

- [ ] **Step 4: Run the focused tests**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.DomainTests
```

Expected: PASS.

- [ ] **Step 5: Commit the domain layer**

```bash
git add Sources/CodexProviderSwitcher/Domain Tests/CodexProviderSwitcherTests/DomainTests.swift
git commit -m "feat: add provider switcher domain settings"
```

### Task 3: Implement deterministic Codex TOML transformation

**Files:**

- Create: `Sources/CodexProviderSwitcher/Config/CodexConfigTransformer.swift`
- Modify: `Tests/CodexProviderSwitcherTests/CodexConfigTransformerTests.swift`

**Interfaces:**

```swift
struct CodexConfigTransformer {
    func validateBaseConfig(_ text: String) throws
    func detectMode(in text: String, settings: DeepSeekSettings) -> ProviderMode
    func makeDeepSeekConfig(from gptConfig: String, settings: DeepSeekSettings) throws -> String
}

enum ConfigTransformError: Error, Equatable {
    case missingRootKey(String)
    case missingProviderTable(String)
    case duplicateKey(String)
    case invalidExistingConfig(String)
}
```

- [ ] **Step 1: Add fixtures and failing tests**

Use a fixture containing the relevant structure from the current config:

```toml
model_provider = "custom"
model = "gpt-5.6-luna"

[model_providers.custom]
name = "OpenAI"
base_url = "https://chatgpt.com/backend-api/codex"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
```

Add tests named:

```swift
func testDeepSeekTransformPreservesUnrelatedConfigAndCustomProviderID()
func testDeepSeekTransformSetsResponsesAndEnvironmentKey()
func testModeDetectionDistinguishesGPTDeepSeekAndUnknown()
func testTransformerRejectsMissingCustomProviderTable()
func testTransformerNeverEmitsAnAPIKeyValue()
```

- [ ] **Step 2: Run the transformer tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.CodexConfigTransformerTests
```

Expected: compilation failure for the missing transformer and error types.

- [ ] **Step 3: Implement a narrow, fail-closed TOML line transformer**

Track the current TOML table while preserving every unrelated line byte-for-byte. Require exactly one root `model` key, one root `model_provider` key with value `"custom"`, and one `[model_providers.custom]` table. Upsert only these provider fields inside that table:

Build the replacement values from `DeepSeekSettings.model`, `DeepSeekSettings.baseURL.absoluteString`, and `DeepSeekSettings.environmentKey`, escaping them as TOML basic strings. The resulting relevant fields must be:

```toml
model = "the configured DeepSeek model"
model_provider = "custom"

[model_providers.custom]
name = "DeepSeek (experimental)"
base_url = "the configured Responses-compatible base URL"
wire_api = "responses"
env_key = "DEEPSEEK_API_KEY"
requires_openai_auth = false
```

The transformer must reject duplicate relevant keys and must not serialize a secret. `detectMode` returns `.deepSeek` only when all DeepSeek fields match; `.gpt` when the provider points at the current ChatGPT endpoint; otherwise `.unknown`.

- [ ] **Step 4: Run the tests and compare exact output**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.CodexConfigTransformerTests
```

Expected: PASS, including an assertion that the original GPT fixture is unchanged when it is used as the source string.

- [ ] **Step 5: Commit the transformer**

```bash
git add Sources/CodexProviderSwitcher/Config/CodexConfigTransformer.swift Tests/CodexProviderSwitcherTests/CodexConfigTransformerTests.swift
git commit -m "feat: transform Codex provider config safely"
```

### Task 4: Add atomic config snapshots and recovery manifest

**Files:**

- Create: `Sources/CodexProviderSwitcher/Config/SnapshotStore.swift`
- Create: `Sources/CodexProviderSwitcher/Config/ManifestStore.swift`
- Modify: `Tests/CodexProviderSwitcherTests/SnapshotStoreTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**

```swift
struct ConfigSnapshot: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let targetMode: ProviderMode
    let configURL: URL
    let sha256: String
}

struct SwitchManifest: Codable, Equatable, Sendable {
    var activeMode: ProviderMode
    var lastGPTSnapshot: ConfigSnapshot?
    var transactionID: String?
    var transactionPhase: String?
}

final class SnapshotStore {
    init(rootURL: URL, fileManager: FileManager = .default)
    func capture(configURL: URL, targetMode: ProviderMode, now: Date) throws -> ConfigSnapshot
    func read(_ snapshot: ConfigSnapshot) throws -> String
    func atomicallyReplace(configURL: URL, with text: String) throws
}

final class ManifestStore {
    init(url: URL, fileManager: FileManager = .default)
    func load() throws -> SwitchManifest
    func save(_ manifest: SwitchManifest) throws
}
```

- [ ] **Step 1: Write failing filesystem tests using a temporary directory**

Add tests named:

```swift
func testCaptureWritesTimestampedSnapshotAndSHA256()
func testAtomicReplaceLeavesNoTemporaryFile()
func testSnapshotReadReturnsTheExactOriginalConfig()
func testManifestRoundTripsAndUses0600Permissions()
func testSnapshotStoreDoesNotTouchASeparateStateDatabase()
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SnapshotStoreTests
```

Expected: compilation failure for the missing store types.

- [ ] **Step 3: Implement snapshot and atomic replacement**

Use `CryptoKit.SHA256` for the snapshot hash. Create snapshots under `~/Library/Application Support/Codex Provider Switcher/snapshots/<timestamp>-<id>/config.toml`. Write replacement text to a temporary file in the same directory, copy the original file permissions, flush/close it, then use `FileManager.replaceItemAt` or an equivalent same-directory rename. Never open the SQLite files in write mode.

- [ ] **Step 4: Implement manifest persistence and crash recovery fields**

Persist `activeMode`, the last GPT snapshot, and transaction phase (`prepared`, `chatGPTStopped`, `configReplaced`, `launched`, or `rolledBack`). Use a temporary JSON file and atomic replacement for the manifest as well.

- [ ] **Step 5: Run the filesystem tests**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SnapshotStoreTests
```

Expected: PASS; the test directory's SQLite sentinel hash remains unchanged.

- [ ] **Step 6: Commit the snapshot layer**

```bash
git add Sources/CodexProviderSwitcher/Config/SnapshotStore.swift Sources/CodexProviderSwitcher/Config/ManifestStore.swift Tests/CodexProviderSwitcherTests/SnapshotStoreTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: add atomic config snapshots and manifest recovery"
```

### Task 5: Add Keychain secrets and one-time `.env` import

**Files:**

- Create: `Sources/CodexProviderSwitcher/Security/SecretStore.swift`
- Create: `Sources/CodexProviderSwitcher/Security/KeychainSecretStore.swift`
- Create: `Sources/CodexProviderSwitcher/Security/EnvFileImporter.swift`
- Modify: `Tests/CodexProviderSwitcherTests/EnvFileImporterTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**

```swift
protocol SecretStore: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

struct EnvFileImporter {
    func readValue(named name: String, from url: URL) throws -> String?
}
```

- [ ] **Step 1: Write failing importer and redaction tests**

Add tests named:

```swift
func testEnvImporterReadsQuotedAndUnquotedDeepSeekKey()
func testEnvImporterIgnoresCommentsAndOtherVariables()
func testEnvImporterReturnsNilForMissingKey()
func testSecretStoreInterfaceDoesNotExposeSecretsInDiagnosticDescription()
```

The tests use a temporary `.env` fixture and assert only equality in memory; they never print the fixture or value.

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.EnvFileImporterTests
```

Expected: compilation failure for the missing importer and protocol.

- [ ] **Step 3: Implement the parser and Keychain adapter**

Parse only `KEY=value` lines, strip one matching pair of single or double quotes, ignore blank/comment lines, and reject a multiline value. Implement `KeychainSecretStore` with `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete` for `kSecClassGenericPassword`. Error descriptions must mention the operation and OSStatus, never the secret.

- [ ] **Step 4: Run the focused tests and build**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.EnvFileImporterTests
swift build
```

Expected: PASS and successful compilation against the macOS Security framework.

- [ ] **Step 5: Commit the security layer**

```bash
git add Sources/CodexProviderSwitcher/Security Tests/CodexProviderSwitcherTests/EnvFileImporterTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: store DeepSeek credentials in Keychain"
```

### Task 6: Implement endpoint preflight without a billable completion request

**Files:**

- Create: `Sources/CodexProviderSwitcher/Provider/EndpointPreflight.swift`
- Modify: `Tests/CodexProviderSwitcherTests/EndpointPreflightTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**

```swift
struct EndpointPreflightReport: Equatable, Sendable {
    let reachable: Bool
    let responsesDeclared: Bool
    let messages: [String]
}

protocol HTTPProbe: Sendable {
    func head(_ url: URL, timeout: Duration) async throws -> Int
}

struct EndpointPreflight {
    let probe: HTTPProbe
    func check(settings: DeepSeekSettings, secretAvailable: Bool) async -> EndpointPreflightReport
}
```

- [ ] **Step 1: Write failing preflight tests**

Add tests named:

```swift
func testPreflightRejectsMissingSecret()
func testPreflightRejectsNonResponsesWireAPI()
func testPreflightTreats401AsReachableButReportsResponsesDeclaration()
func testPreflightRejectsMalformedURLOrUnsupportedScheme()
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.EndpointPreflightTests
```

Expected: compilation failure for the missing preflight types.

- [ ] **Step 3: Implement static checks and a no-body HEAD probe**

Require a nonempty model, `wireAPI == "responses"`, `http` or `https`, and an available Keychain secret. Send only a `HEAD` request without an Authorization header or request body. Treat HTTP 200–499 as network-reachable and report that the configuration declares Responses; this is a declaration, not proof that the third-party endpoint implements every Codex feature. Never send a completion prompt automatically.

- [ ] **Step 4: Run the preflight tests**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.EndpointPreflightTests
```

Expected: PASS, including the 401 reachability case and no request body assertion.

- [ ] **Step 5: Commit the preflight layer**

```bash
git add Sources/CodexProviderSwitcher/Provider/EndpointPreflight.swift Tests/CodexProviderSwitcherTests/EndpointPreflightTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: preflight DeepSeek endpoint safely"
```

### Task 7: Implement ChatGPT process lifecycle control

**Files:**

- Create: `Sources/CodexProviderSwitcher/Process/ProcessTable.swift`
- Create: `Sources/CodexProviderSwitcher/Process/ChatGPTProcessController.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**

```swift
protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async
}

protocol ChatGPTProcessControlling: Sendable {
    func isRunning() -> Bool
    func requestTermination() async throws
    func waitUntilStopped(timeout: Duration) async -> Bool
    func launch(environment: [String: String]) throws
}

struct ChatGPTProcessController: ChatGPTProcessControlling {
    let applicationURL: URL
    let processTable: ProcessTable
    let sleeper: any Sleeper
    func isRunning() -> Bool
    func requestTermination() async throws
    func waitUntilStopped(timeout: Duration) async -> Bool
    func launch(environment: [String: String]) throws
}
```

- [ ] **Step 1: Write failing lifecycle tests using a fake controller**

Add coordinator-facing tests for:

```swift
func testRequestTerminationIsGraceful()
func testWaitUntilStoppedReturnsFalseOnTimeout()
func testLaunchReceivesOnlyTheDeepSeekEnvironmentKeyInDeepSeekMode()
func testGPTLaunchDoesNotReceiveDeepSeekEnvironmentKey()
```

- [ ] **Step 2: Implement process inspection with fixed executable paths**

Use `NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")` for the GUI app. Use a fixed-argument `/bin/ps` subprocess to detect the known ChatGPT Codex app-server executable under `/Applications/ChatGPT.app/Contents/Resources/codex`; do not construct shell commands from user input. `requestTermination` must use `NSRunningApplication.requestTerminate()` and wait for both the GUI app and matching app-server rows to disappear.

- [ ] **Step 3: Implement environment-injected launch**

Launch `/Applications/ChatGPT.app/Contents/MacOS/ChatGPT` as a child process with a copy of the current environment. In DeepSeek mode add only `DEEPSEEK_API_KEY` read from `SecretStore`; in GPT mode remove `DEEPSEEK_API_KEY`. Set standard output and error to a pipe owned by the controller and discard/redact any output before it reaches logs.

- [ ] **Step 4: Run the lifecycle tests**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SwitchTransactionCoordinatorTests
```

Expected: the fake controller tests pass without launching the real ChatGPT app.

- [ ] **Step 5: Commit the process layer**

```bash
git add Sources/CodexProviderSwitcher/Process Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: control ChatGPT lifecycle safely"
```

### Task 8: Implement the switch transaction and rollback coordinator

**Files:**

- Create: `Sources/CodexProviderSwitcher/Switch/SwitchTransactionCoordinator.swift`
- Create: `Sources/CodexProviderSwitcher/Support/Clock.swift`
- Modify: `Tests/CodexProviderSwitcherTests/SwitchTransactionCoordinatorTests.swift`
- Modify: `Tests/CodexProviderSwitcherTests/TestDoubles.swift`

**Interfaces:**

```swift
protocol Clock: Sendable {
    var now: Date { get }
}

struct SwitchResult: Equatable, Sendable {
    let targetMode: ProviderMode
    let snapshotID: String?
}

enum SwitchError: Error, Equatable {
    case alreadyRunning
    case unknownCurrentMode
    case preflightFailed([String])
    case chatGPTDidNotStop
    case configurationWriteFailed(String)
    case launchFailed(String)
    case rolledBack(String)
}

protocol SwitchLocking: Sendable {
    func acquire() throws
    func release()
}

final class SwitchTransactionCoordinator {
    init(
        settings: SwitchSettings,
        transformer: CodexConfigTransformer,
        snapshotStore: SnapshotStore,
        manifestStore: ManifestStore,
        secretStore: any SecretStore,
        preflight: EndpointPreflight,
        processController: any ChatGPTProcessControlling,
        lock: any SwitchLocking,
        clock: any Clock
    )

    func currentMode() throws -> ProviderMode
    func switchTo(_ target: ProviderMode) async throws -> SwitchResult
}
```

- [ ] **Step 1: Write failing transaction tests**

Add tests named:

```swift
func testDeepSeekSwitchSnapshotsQuitsTransformsLaunchesAndUpdatesManifest()
func testGPTSwitchRestoresTheLastGPTSnapshot()
func testUnknownCurrentModeStopsBeforeWriting()
func testChatGPTTimeoutLeavesConfigAndHistorySentinelUnchanged()
func testConfigWriteFailureRestartsGPTFromSnapshot()
func testLaunchFailureRestoresGPTAndRecordsRollback()
func testConcurrentSwitchIsRejectedByTheLock()
func testSecretNeverAppearsInArgumentsOrDiagnosticText()
```

Use a temporary Codex home with a config fixture and a sentinel `state_5.sqlite` file. Fake `SecretStore`, `HTTPProbe`, process controller, clock, and lock so every test is deterministic.

- [ ] **Step 2: Run the transaction tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SwitchTransactionCoordinatorTests
```

Expected: compilation failure until the coordinator and fakes are defined.

- [ ] **Step 3: Implement the success path in explicit phases**

The coordinator must execute this order:

```text
acquire lock
→ load manifest and detect current mode
→ no-op if current mode equals target
→ validate target settings and Keychain secret
→ run endpoint preflight for DeepSeek
→ mark manifest prepared
→ capture current config snapshot
→ request graceful ChatGPT termination
→ wait for GUI and app-server stop
→ mark manifest chatGPTStopped
→ generate target config and atomically replace it
→ mark manifest configReplaced
→ launch ChatGPT with the correct environment
→ mark manifest launched and activeMode
→ release lock
```

When switching to GPT, restore the `lastGPTSnapshot` captured before the current DeepSeek session. When switching to DeepSeek, capture the current GPT config as the new restore snapshot. Never edit the SQLite sentinel or real history files.

- [ ] **Step 4: Implement rollback for every post-snapshot failure**

On timeout, transform failure, write failure, launch failure, or manifest failure:

```text
best-effort graceful termination of the new process
→ atomically restore the saved GPT snapshot
→ launch ChatGPT without DeepSeek environment
→ record rolledBack phase and error message
→ release lock
→ throw a user-facing SwitchError
```

If ChatGPT does not stop before the snapshot is taken, abort before replacing the config and leave the original file byte-for-byte unchanged.

- [ ] **Step 5: Run the transaction tests**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.SwitchTransactionCoordinatorTests
```

Expected: PASS; the temporary history sentinel hash and content are identical before and after every test.

- [ ] **Step 6: Commit the coordinator**

```bash
git add Sources/CodexProviderSwitcher/Switch Sources/CodexProviderSwitcher/Support Tests/CodexProviderSwitcherTests/SwitchTransactionCoordinatorTests.swift Tests/CodexProviderSwitcherTests/TestDoubles.swift
git commit -m "feat: add reversible provider switch transaction"
```

### Task 9: Add the simple native UI and command-line launch intents

**Files:**

- Create: `Sources/CodexProviderSwitcher/App/AppModel.swift`
- Create: `Sources/CodexProviderSwitcher/App/MainView.swift`
- Modify: `Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift`
- Create: `Tests/CodexProviderSwitcherTests/AppModelTests.swift`

**Interfaces:**

```swift
enum LaunchIntent: Equatable {
    case interactive
    case switchTo(ProviderMode)
    case checkOnly
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var currentMode: ProviderMode = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastSnapshotURL: URL?
    @Published var showDeepSeekKeyPrompt = false

    func refresh() async
    func switchToDeepSeek() async
    func switchToGPT() async
    func runPreflight() async
    func revealSnapshots()
    func revealLogs()
}
```

- [ ] **Step 1: Write failing view-model tests**

Test that successful and failed coordinator results update `currentMode`, `isBusy`, `statusMessage`, and `lastSnapshotURL`; test that `LaunchIntent.switchTo(.deepSeek)` calls the coordinator exactly once and that `.checkOnly` never writes config. Use an injected fake coordinator and temporary URLs.

- [ ] **Step 2: Run the UI model tests and verify they fail**

Run:

```bash
swift test --filter CodexProviderSwitcherTests.AppModelTests
```

Expected: compilation failure for `AppModel` and its dependency injection initializer.

- [ ] **Step 3: Implement a compact single-window SwiftUI layout**

Create `MainView` with:

```text
┌────────────────────────────────────┐
│ Codex Provider Switcher             │
│ 当前模式  GPT / DeepSeek / 未知     │
│                                    │
│ [切到 DeepSeek并重启 ChatGPT]       │
│ [切回 GPT并重启 ChatGPT]             │
│                                    │
│ [仅检查]  [打开备份]  [打开日志]     │
│ 最近状态：……                       │
│ ⚠ DeepSeek 为实验性 provider        │
└────────────────────────────────────┘
```

Use system colors, standard macOS controls, no external assets, and a fixed minimum window size rather than a custom heavy design. Disable both primary actions while `isBusy` is true. Add a confirmation alert for DeepSeek explaining that old-session continuation is not guaranteed.

- [ ] **Step 4: Add the menu-bar scene**

Change the app scene to contain both:

```swift
WindowGroup("Codex Provider Switcher") {
    MainView(model: model)
}

MenuBarExtra("Codex Provider Switcher", systemImage: "arrow.triangle.2.circlepath") {
    Button("切到 DeepSeek并重启 ChatGPT") { Task { await model.switchToDeepSeek() } }
    Button("切回 GPT并重启 ChatGPT") { Task { await model.switchToGPT() } }
    Divider()
    Button("打开主窗口") { WindowRouter.shared.openMainWindow() }
    Button("退出") { NSApplication.shared.terminate(nil) }
}
```

The app must use dependency-injected settings and `FileManager.homeDirectoryForCurrentUser`; no Swift source may contain `/Users/mac`.

Define `WindowRouter` in `Sources/CodexProviderSwitcher/App/CodexProviderSwitcherApp.swift` with `static let shared` and `func openMainWindow()`. It should activate the app and bring the first `WindowGroup` window to the front using AppKit, without touching provider configuration.

- [ ] **Step 5: Implement command-line intent parsing**

Support exactly these arguments:

```text
--mode=deepseek
--mode=gpt
--check
```

The two desktop wrappers use the first two forms. In intent mode the app executes once, displays a native notification or alert with the result, then exits; interactive launch stays as a menu-bar app. The intent parser must also accept `--codex-home <path>` and `--chatgpt-app <path>` for open-source users and test fixtures, while production wrappers omit both flags and use the current user's defaults.

- [ ] **Step 6: Run all Swift tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit the UI layer**

```bash
git add Sources/CodexProviderSwitcher/App Tests/CodexProviderSwitcherTests/AppModelTests.swift
git commit -m "feat: add simple SwiftUI switcher interface"
```

### Task 10: Package the app and install safe desktop launchers

**Files:**

- Create: `scripts/package-app.sh`
- Create: `scripts/install-desktop-launchers.sh`
- Modify: `README.md`

**Interfaces:**

- `scripts/package-app.sh <staging-directory>` produces:
  - `<staging-directory>/Codex Provider Switcher.app`
  - `<staging-directory>/Codex 切到 DeepSeek.app`
  - `<staging-directory>/Codex 切回 GPT.app`
- `scripts/install-desktop-launchers.sh <staging-directory>` installs the main app into `~/Applications` and the two wrapper bundles into `~/Desktop`.

- [ ] **Step 1: Write packaging validation commands**

After packaging, set `app_path` to the bundle being checked and run exactly:

```bash
app_path="$1"
plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "$app_path"
test -x "$app_path/Contents/MacOS/CodexProviderSwitcher"
```

Use an ad-hoc signature (`codesign --force --deep --sign -`) so the locally built app can launch without a developer certificate. Do not disable Gatekeeper globally.

- [ ] **Step 2: Implement `package-app.sh`**

Run `swift build -c release`, create the bundle directories, copy the executable, generate an `Info.plist` with bundle identifier `local.codex.provider-switcher`, set `LSUIElement=false` for the main app so the simple window can be shown, and create two wrapper bundles with display names and only `--mode=deepseek` or `--mode=gpt` arguments. The wrappers must not contain or pass any secret.

- [ ] **Step 3: Implement safe installation**

Install only when an existing target is absent or has the expected bundle identifier `local.codex.provider-switcher`. If a target with the same display name has a different bundle identifier, stop and report the conflict rather than replacing it. Set executable permissions and keep the existing `DeepSeek V4 Flash Max.command` file untouched.

- [ ] **Step 4: Add a non-destructive first-run path**

The installed app must open the UI without automatically switching provider, quitting ChatGPT, reading a model response, or replacing `config.toml`. The first visible action is status detection; DeepSeek credentials are requested only when the user explicitly starts preflight or a DeepSeek switch.

- [ ] **Step 5: Package and validate in staging**

Run:

```bash
rm -rf /tmp/codex-provider-switcher-staging
mkdir -p /tmp/codex-provider-switcher-staging
bash scripts/package-app.sh /tmp/codex-provider-switcher-staging
plutil -lint "/tmp/codex-provider-switcher-staging/Codex Provider Switcher.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=1 "/tmp/codex-provider-switcher-staging/Codex Provider Switcher.app"
```

Expected: all three app bundles exist, plist validation passes, and code-signature verification succeeds.

- [ ] **Step 6: Install the desktop entries**

Run:

```bash
bash scripts/install-desktop-launchers.sh /tmp/codex-provider-switcher-staging
```

Expected: the main app is under `~/Applications`, the two wrapper apps are on the desktop, and the existing `DeepSeek V4 Flash Max.command` file remains untouched.

- [ ] **Step 7: Commit packaging**

```bash
git add scripts README.md
git commit -m "feat: package desktop provider switcher"
```

### Task 11: Make the repository safe to open-source later

**Files:**

- Create: `.gitignore`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `docs/architecture.md`
- Modify: `README.md`

**Interfaces:**

- No runtime interface changes; this task documents the safety contract and prevents accidental personal-data commits.

- [ ] **Step 1: Add repository ignore rules**

`.gitignore` must ignore at least:

```gitignore
.build/
.swiftpm/
DerivedData/
*.xcuserstate
.env
auth.json
*.sqlite
*.sqlite-shm
*.sqlite-wal
sessions/
snapshots/
logs/
```

Do not add a blanket ignore for source files or the design/plan documents.

- [ ] **Step 2: Document contribution and security rules**

`CONTRIBUTING.md` must require tests with temporary homes, prohibit real API keys in issues/PRs, and require `swift test` before review. `SECURITY.md` must ask users to remove API keys and personal history before sharing diagnostics and must state that the app modifies local Codex configuration.

- [ ] **Step 3: Document the architecture and portability boundary**

`docs/architecture.md` must describe the domain/config/security/provider/process/switch/UI boundaries, the transaction phases, the no-database-write rule, the Keychain flow, and the two wrapper intents. It must state that `/Users/mac` is only an example deployment path and is not embedded in the source.

- [ ] **Step 4: Update README for open-source readiness without choosing a license**

README must include build commands, UI usage, wrapper installation, snapshots/logs location, known DeepSeek Responses compatibility limits, recovery steps, and a note that no open-source license has been selected yet. Do not add or claim a license in this task.

- [ ] **Step 5: Scan the repository for secrets and personal paths**

Run:

```bash
rg -n --hidden -g '!/.git/**' -g '!/.build/**' 'sk-[A-Za-z0-9]|DEEPSEEK_API_KEY=[^$<]|/Users/mac|auth\.json|state_5\.sqlite' .
```

Expected: only intentional documentation examples or deployment notes remain; no real secret, auth file, history database, or hardcoded runtime path appears in Swift source or scripts.

- [ ] **Step 6: Commit repository hygiene**

```bash
git add .gitignore CONTRIBUTING.md SECURITY.md docs/architecture.md README.md
git commit -m "docs: prepare provider switcher for future open source"
```

### Task 12: Run safe end-to-end verification without changing the live provider

**Files:**

- Modify only if tests expose a defect: files from Tasks 1–11.

- [ ] **Step 1: Run the full test suite and release build**

Run:

```bash
swift test
swift build -c release
```

Expected: all tests pass and the release binary builds.

- [ ] **Step 2: Run the app's temporary-home self-check**

Add a test-only invocation that points the coordinator at a temporary Codex home containing the fixture config and a sentinel `state_5.sqlite`; run both target modes using fake process and network dependencies. Assert:

```text
fixture config restores byte-for-byte
sentinel state_5.sqlite hash is unchanged
DeepSeek key appears only in the fake child environment
rollback relaunches GPT without the DeepSeek environment
```

- [ ] **Step 3: Verify the live home is unchanged**

Before installation, record read-only hashes/counts for:

```text
/Users/mac/.codex/config.toml
/Users/mac/.codex/state_5.sqlite
/Users/mac/.codex/state_5.sqlite-wal
/Users/mac/.codex/state_5.sqlite-shm
```

After packaging and installing the app, verify the same files have unchanged hashes and that the provider count remains `custom = 142`. Do not click the DeepSeek launcher during automated verification.

- [ ] **Step 4: Run only the non-mutating production diagnostics**

Launch the installed app with `--check`. It may read the current configuration and check Keychain/endpoint metadata, but it must not quit ChatGPT, write `config.toml`, or contact the model with a completion request. Confirm that diagnostics redact the API key.

- [ ] **Step 5: Perform the first live switch only with an explicit user action**

After the app is installed and diagnostics pass, the user may click “切到 DeepSeek并重启 ChatGPT”. Before that click, report the current endpoint, whether the Responses compatibility check is verified, and the snapshot path. The agent must not trigger the live switch automatically as part of build verification.

- [ ] **Step 6: Commit final verification notes**

```bash
git add README.md docs/superpowers/plans/2026-08-08-codex-provider-switcher.md
git commit -m "test: document provider switcher verification"
```

## Self-Review Checklist

- **Spec coverage:** Tasks 2–3 cover provider identity and Responses-only TOML transformation; Task 4 covers snapshots and atomic writes; Task 5 covers Keychain and `.env` import; Task 6 covers endpoint preflight; Task 7 covers graceful process lifecycle and environment injection; Task 8 covers transaction order, rollback, lock, and history immutability; Task 9 covers the simple SwiftUI window, menu-bar controls, and desktop intents; Task 10 covers packaging and installation; Task 11 covers open-source hygiene and personal-data exclusion; Task 12 covers temporary-home and live-home verification.
- **Placeholder scan:** The plan contains no `TBD`, `TODO`, “fill in details”, or unassigned implementation step. Every task names files, interfaces, tests, commands, and expected outcomes.
- **Type consistency:** `ProviderMode`, `DeepSeekSettings`, `SwitchSettings`, `ConfigSnapshot`, `SwitchManifest`, `SecretStore`, `EndpointPreflight`, `ChatGPTProcessControlling`, `SwitchTransactionCoordinator`, `LaunchIntent`, and `AppModel` are defined before later tasks consume them.
- **Safety consistency:** All real-home writes are behind the transaction coordinator; tests use temporary homes; the live switch is explicitly user-triggered; the SQLite history is never opened for writes; the UI is separate from the switching engine.
