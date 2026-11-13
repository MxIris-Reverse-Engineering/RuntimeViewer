# AGENTS.md — RuntimeViewerPackages tests

How to build and run these suites: the root `AGENTS.md`, *Testing*.

The application layer has two test targets and a library they share
(`Documentations/Evolutions/draft-app-core-ui-split.md`):

- **`RuntimeViewerAppCoreTests`** tests `RuntimeViewerAppCore` with nothing of the UI layer linked: no
  `RuntimeViewerAppUI`, `RuntimeViewerUI`, AppKitPlus or UIFoundation. Every ViewModel in
  `RuntimeViewerAppCore` has a contract suite here, next to the defect-specific regression suites, and so
  do `CrossPlatformSourceGuardTests` and `AppCoreBoundaryTests`, which read the package's sources
  (`Support/PackageSourceScan.swift`). A test that needs a view, a control or a UI library — even one
  case of a suite — goes in the other target.
- **`RuntimeViewerAppUITests`** tests the UI layer: `RuntimeViewerAppUI`'s adapters and live
  implementations, `RuntimeViewerUI`'s views, and what `RuntimeViewerAppCore` rewrote from a UI library
  checked against that library (`FindPatternParityTests`, `IDEIconRuntimeObjectIconRendererTests`,
  `RowTextAttributedStringTests`).
- **`RuntimeViewerAppTestingSupport`** (`Tests/RuntimeViewerAppTestingSupport`) holds what both use:
  `ViewModelTestEnvironment`, `TestRuntimeEngine`, the fixtures, waiting on Rx, `pollUntil`,
  `MockRouter`, and Xcode's find patterns as `FindPattern`s. Its declarations are `package`, and it
  reaches into `RuntimeViewerAppCore` and `RuntimeViewerSettings` only through their `package` test
  seams (`AppDefaults(storageDirectoryURL:userDefaultsNamespace:)`, `SettingsAccess.preview` and the
  like), never `@testable import`: it is a library product, which `swift build -c release` builds too,
  and which an app could link by mistake. It is a product only because Tuist maps no target outside one,
  and a test target depending on such a target fails to generate. It imports no UI library and not
  `Testing`. A helper only one target uses stays in that target's `Support/`.

Each test target builds into a bundle of its own and runs in a process of its own — in Xcode, and in
`swift test` with Xcode 27's toolchain — so `RuntimeViewerAppCoreTests` runs without
`RuntimeViewerAppUI`, and the live implementations of `appRouter`, `runtimeEngineIconProviding` and
`runtimeObjectIconRendering` are not there: a test that reads one of them in a live dependency context
reports an issue. Override the dependency instead.

Rules for both test targets:

- **Build ViewModels inside `ViewModelTestEnvironment.make { }`.** It overrides `appDefaults`, `settings`
  and `resolvedThemeStream` with test-owned instances. `AppDefaults` is file-backed under a path the
  running app shares (`~/Library/Application Support/AppStorage`, not bundle-scoped, and the app is not
  sandboxed), so a test that resolves `AppDefaults.shared` reads and writes the user's real bookmark files.
  The key's `testValue` is an isolated temporary-directory instance for that reason, and
  `withLiveDependencyContext` pins the same — never point either back at `.shared`. A suite that writes
  its own live-context helper has to pin `\.appDefaults` as well: `ContentTextPipelineTests` shadowed the
  shared helper with one that did not, and reached `.shared` until PR121.18. An isolated instance also
  keeps its Generation Options, filter mode and migration flags in a user defaults namespace of its own
  (`UserDefaultsNamespace`), so tests neither hear each other's option changes nor write the test
  process's standard defaults, and need no lock around them. `settings` is `SettingsAccess.preview`
  (in-memory); the live one auto-saves over the user's `RuntimeViewer-Debug/settings.json`.
- **Derived data stays in a `DerivedDataFixture`** (`RuntimeViewerAppCoreTests/Support/DerivedDataFixture.swift`): a store in a temporary
  directory of the test's own, handed to an engine through `RuntimeEngine.useDerivedDataStore(_:)`. Never call
  `RuntimeDerivedData.enableInThisProcess()` in a test — it is the two services' switch, and once on it points
  every engine made afterwards in the test process at the real `~/Library/Caches/<bundle identifier>/DerivedData`,
  which the app's services read at their next launch (`RuntimeViewerCore/Tests/AGENTS.md`).
- **Engine-backed behaviour uses a real in-process `RuntimeEngine`**, the same way RuntimeViewerCore's
  tests do: `TestRuntimeEngine.shared()` (a dedicated engine with libobjc + Foundation loaded once per
  process; never call `loadImage` on it) or `TestRuntimeEngine.makeConnected(...)` for tests that change
  engine state. ViewModels bound to it through `.switchEngine` do not need `withSharedLocalEngineLock`;
  that lock is for tests coupled to `RuntimeEngine.local`. Anchor assertions on stable symbols
  (`NSObject`, `NSString`, `NSMutableString`).
- **Keep the ViewModel alive until the assertion** (`defer { withExtendedLifetime(viewModel) {} }`):
  `transform` handlers capture `[weak self]`, so a dropped ViewModel silently does nothing.
- **Await Rx through the helpers**: `nextValue(from:where:)` for the first matching element,
  `values(from:during:)` to prove nothing was emitted. Navigation is asserted on `DocumentState`
  (`selectedRuntimeObject`, `tabs`) or on a `MockRouter`.

Design notes and the per-ViewModel coverage table: `Documentations/Evolutions/0016-application-viewmodel-tests.md`.
