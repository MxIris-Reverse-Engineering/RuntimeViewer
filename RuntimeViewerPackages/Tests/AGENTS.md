# AGENTS.md — RuntimeViewerPackages tests

How to build and run these suites: the root `AGENTS.md`, *Testing*.

Rules for `RuntimeViewerApplicationTests` (every ViewModel in `RuntimeViewerApplication` has a contract
suite there, next to the defect-specific regression suites):

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
- **Derived data stays in a `DerivedDataFixture`** (`Support/DerivedDataFixture.swift`): a store in a temporary
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
