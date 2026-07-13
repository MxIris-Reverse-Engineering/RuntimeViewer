# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Runtime Viewer is a macOS/iOS document-based (NSDocument) application for inspecting Objective-C and Swift runtime interfaces. It serves as a modern alternative to RuntimeBrowser with features like Swift interface support, type-defined jumps, Xcode-style syntax highlighting, code injection capabilities, and MCP (Model Context Protocol) integration for LLM clients.

## Build Commands

**Workspace preference**: Before running any `xcodebuild` / `swift build` / `swift test`, check whether `../MxIris-Reverse-Engineering.xcworkspace` (sibling of this repo) exists. If it does, **use that workspace** via `xcodebuild -workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme <scheme> ...` — it wires this repo together with local checkouts of MachOKit / MachOObjCSection / MachOSwiftSection / swift-capstone / swift-demangling / swift-semantic-string / swift-syntax that may contain in-progress fixes not yet published upstream. Building against the remote SPM resolution can hit stale errors (e.g. the MachOSwiftSection `@Mutex` macro expansion bug) that the workspace's local checkout already fixes. Only fall back to the standalone commands below when the workspace is absent.

**Catalyst helper build order**: For native macOS builds, build
`RuntimeViewerCatalystHelper` first, then build `RuntimeViewer macOS` /
`RuntimeViewerUsingAppKit` in the same Xcode/DerivedData session. Do not model
this as a direct target dependency: Xcode treats the Mac Catalyst helper as
iOS-family embedded content and rejects it from the macOS app target.
`RunScript.sh` and `ArchiveScript.sh` both already handle this by building/
archiving the helper before the main app.

Recommended Xcode order:
1. Build `RuntimeViewerCatalystHelper` for `My Mac (Mac Catalyst)`.
2. Build `RuntimeViewer macOS` for `My Mac`.

```bash
# Debug build + launch (configuration "Debug-arm64e", workspace
# RuntimeViewer-Debug.xcworkspace, scheme "RuntimeViewer macOS"; builds
# RuntimeViewerCatalystHelper first, then the main app). This is the only
# working path for Debug-arm64e — the Xcode GUI fails to compile under
# iOSPackagesShouldBuildARM64e=true. Product: RuntimeViewer-Debug-arm64e.app
# under /Volumes/DerivedData/RuntimeViewer/Debug-arm64e when that volume
# exists (project-relative DerivedData otherwise).
./RunScript.sh
./RunScript.sh --no-launch         # build only
./RunScript.sh --update-packages   # refresh SPM pins before building
./RunScript.sh --dry-run           # print commands without running

# Release build (archives Catalyst helper + main app, notarizes, and optionally
# generates appcast + uploads GitHub Release). Uses scheme "RuntimeViewer macOS".
# Omit the distribution flags for a local signed zip only.
./ArchiveScript.sh
# Cut a full release (appcast + GitHub Release + commit docs/appcast.xml):
./ArchiveScript.sh --update-appcast --upload-to-github --commit-push --version-tag vX.Y.Z

# Build RuntimeViewerServer XCFramework (all platforms)
./BuildRuntimeViewerServerXCFramework.sh
```

**Workspaces**: `RuntimeViewer-Debug.xcworkspace` (used by `RunScript.sh`)
already wires the local sibling checkouts of MachOKit / MachOObjCSection /
MachOSwiftSection / swift-demangling / swift-semantic-string plus the
precompiled swift-syntax, so Debug builds pick up in-progress fixes in those
repos without touching remote SPM pins. `RuntimeViewer-Distribution.xcworkspace`
serves release archives.

**Build Schemes**:
- `RuntimeViewer macOS` — main app; Debug-arm64e via `RunScript.sh`, Release archives via `ArchiveScript.sh`
- `RuntimeViewerCatalystHelper` — Mac Catalyst helper, always built before the main app
- `RuntimeViewerUsingAppKit` — plain Debug builds of the AppKit app target

## Architecture

### Package Structure

The project uses three Swift Package Manager packages:

**RuntimeViewerCore** (`RuntimeViewerCore/`):
- `RuntimeViewerCore` — Runtime inspection engine using MachOObjCSection (ObjC) and MachOSwiftSection (Swift)
- `RuntimeViewerCommunication` — XPC/TCP-based IPC layer for cross-process inspection
- `RuntimeViewerCoreObjC` — Objective-C interop utilities (internal target)

**RuntimeViewerPackages** (`RuntimeViewerPackages/`):
- `RuntimeViewerArchitectures` — MVVM + Coordinator pattern with RxSwift
- `RuntimeViewerApplication` — ViewModels and business logic (Sidebar, Inspector, Content, Theme, FilterEngine)
- `RuntimeViewerUI` — AppKit UI components (MinimapView, StatefulOutlineView, skeleton effects)
- `RuntimeViewerService` — XPC service helpers and code injection
- `RuntimeViewerServiceHelper` — Helper utilities
- `RuntimeViewerHelperClient` — Helper client for XPC communication
- `RuntimeViewerSettings` — Settings models and dependency values
- `RuntimeViewerSettingsUI` — Settings UI (SwiftUI)
- `RuntimeViewerCatalystExtensions` — Mac Catalyst support

**RuntimeViewerMCP** (`RuntimeViewerMCP/`) — MCP integration (macOS 15+ only):
- `RuntimeViewerMCPShared` — Shared protocols and transport types
- `RuntimeViewerMCPBridge` — Bridge server that runs inside the main app

### Application Targets

- `RuntimeViewerUsingAppKit` — Main macOS application (AppKit, document-based)
- `RuntimeViewerMCPServer` — MCP server executable (stdio-based, communicates with bridge via TCP)
- `RuntimeViewerServer` — XPC background service for inter-process communication
- `RuntimeViewerCatalystHelper` — Mac Catalyst support bridge
- `RuntimeViewerUsingUIKit` — iOS variant (secondary)

### Key Architectural Patterns

- **Document-Based App**: NSDocument architecture; each document creates its own `DocumentState` instance
- **MVVM-C (MVVM + Coordinator)**: Navigation via CocoaCoordinator (macOS) / XCoordinator (iOS)
- **Reactive Streams**: Heavy RxSwift usage for UI state and data flow
- **Dependency Injection**: Uses swift-dependencies for service injection
- **Multi-Process**: XPC services enable safe inspection of external processes
- **MCP Bridge**: TCP bridge pattern — app hosts bridge server, external MCP server connects as client

### MCP Integration

The MCP feature enables LLM clients (e.g., Claude) to inspect runtime information via the Model Context Protocol.

**Architecture**:
```
RuntimeViewerApp (NSDocument)
    ↓ provides DocumentState
AppMCPBridgeWindowProvider
    ↓ bridge (TCP, length-prefixed JSON)
RuntimeViewerMCPBridge (library, in-process)
    ↓ TCP server
RuntimeViewerMCPServer (executable, stdio MCP)
    ↓ MCP protocol
LLM Client
```

- Bridge uses simple length-prefixed JSON over TCP (not RuntimeViewerCommunication framework)
- Port file: `~/Library/Application Support/RuntimeViewer/mcp-bridge-port`
- Bridge starts automatically in `AppDelegate.applicationDidFinishLaunching`
- MCP server entry: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/main.swift`

### UI Technology Stack

- **AppKit**: All UI components except Settings
- **SwiftUI**: Settings module only

## Development Guidelines

When adding new features, you **MUST** follow these rules:

1. **UI Framework**: Use AppKit for all new UI components (except Settings-related features which use SwiftUI)
2. **Architecture**: Follow MVVM-C pattern
   - **Model**: Data structures and business logic
   - **View**: AppKit views (NSView, NSViewController)
   - **ViewModel**: RxSwift-based, handles UI state and logic
   - **Coordinator**: Manages navigation and flow
3. **Reactive**: Use RxSwift for data binding and event handling
4. **No SwiftUI** in non-Settings areas — keep the codebase consistent
5. **Swift Language Mode**: All packages use `swiftLanguageModes: [.v5]`
6. **Singletons go through `@Dependency`**: every project singleton is declared `fileprivate static let shared` and exposed only via a `DependencyKey` + `extension DependencyValues` accessor. Callers consume it through `@Dependency(\.xxx)`. Never `public static let shared`, never `Foo.shared.bar()` from outside the defining file. See **Singletons & Dependency Injection** under Code Style.
7. **AppDelegate stays thin**: AppDelegate is a dispatch shell, not a service container. Every non-trivial lifecycle responsibility (appearance, debug menu, update checking, version probes, etc.) lives in its own `@MainActor` controller class under `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`, registered via `@Dependency` per rule #6. See **AppDelegate Convention** under Code Style.

## Code Style

### Naming Conventions

- **ViewController** classes must always end with `ViewController` suffix (e.g., `MCPStatusPopoverViewController`, NOT `MCPStatusPopoverController`)
- **ViewModel** classes must always end with `ViewModel` suffix (e.g., `MCPStatusPopoverViewModel`)

### Access Control

- All members should be `private` by default; only widen the access level when external access is actually needed
- ViewModel `@Observed` state properties: `@Observed private(set) var`
- ViewController relays: `private let xxxRelay = PublishRelay<Void>()`
- ViewController views: `private let xxxLabel = Label()`

### Singletons & Dependency Injection

**Every project singleton MUST be hidden behind `@Dependency`. No exceptions.** Direct `XxxService.shared.foo()` access from outside the defining file is forbidden — the language enforces it because `shared` is `fileprivate`.

**Pattern** (for `@MainActor` singletons — the common case in this codebase):

```swift
@MainActor
public final class MyService {
    fileprivate static let shared = MyService()

    @Dependency(\.someUpstream) private var someUpstream

    private init() {}

    public func start() { /* ... */ }
    public func stop()  { /* ... */ }
}

// MARK: - Dependencies

private enum MyServiceKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = MyService.shared
}

extension DependencyValues {
    public var myService: MyService {
        get { self[MyServiceKey.self] }
        set { self[MyServiceKey.self] = newValue }
    }
}
```

For non-`@MainActor` singletons, drop `@preconcurrency` and the `@MainActor` on `liveValue`:

```swift
private enum MyServiceKey: DependencyKey {
    static let liveValue = MyService.shared
}
```

**Consumers** always go through `@Dependency`:

```swift
final class MyConsumer {
    @Dependency(\.myService) private var myService

    func doWork() { myService.start() }
}
```

**Rules**:
- `static let shared` is **always** `fileprivate` (never `public`, never plain `static let`). The DependencyKey lives in the same file, so it can see `shared`; nothing else can.
- The `DependencyKey` enum is `private`; the `DependencyValues` accessor is `public` (or matches the singleton's visibility).
- Pick a key path name that matches the type, lowercased: `MyService` → `\.myService`, `HelperServiceManager` → `\.helperServiceManager`.
- Test value: usually omit (defaults to `liveValue`); add `testValue` only when tests need an isolated/no-op variant.
- Access modifier on the `DependencyValues` accessor matches reach: `public` if used outside the module, `package` / internal otherwise.

**Exceptions** (narrow):
- If the enclosing type is **already** `private` / `fileprivate` (e.g. a file-scoped helper class like `EmptyRouteTransitionContext`), the static `shared` is already file-scoped — leave it `static let shared`. Adding `fileprivate` triggers a redundant-modifier warning.
- Apple SDK singletons (`NSApplication.shared`, `NSWorkspace.shared`, `NSDocumentController.shared`, `UserDefaults.standard`, `FileManager.default`, …) are not project singletons — use them directly without wrapping.

**Anti-patterns** — if you catch yourself writing any of these, stop and apply the pattern above:
- `public static let shared = Foo()` in a project type
- `Foo.shared.bar()` at a call site outside `Foo.swift`
- A new project class that owns shared state but skips the `DependencyKey` boilerplate
- Importing a module purely to reach `Foo.shared` instead of going through `@Dependency(\.foo)`

### AppDelegate Convention

**AppDelegate is a dispatch shell, not a service container.** Treat it like a router that translates app lifecycle into one-line calls on injected services.

**Allowed in AppDelegate** (and nothing else):
- Lifecycle hooks (`applicationDidFinishLaunching`, `applicationWillTerminate`, `applicationSupportsSecureRestorableState`, `applicationShouldTerminateAfterLastWindowClosed`, `application(_:open:)`, …)
- `@Dependency(\.xxx)` declarations for the controllers/services it dispatches to
- `IBAction` methods that immediately delegate to a router or injected service (one line each)
- One-line `start()` / `install()` / `stop()` / `checkOnLaunch()` calls on injected services
- Compile-time flag toggles like `runtimeViewerIsARM64EVariant = true` and one-shot fixes like `NSToolbarItemViewerOverflowFix.install()`

**Forbidden in AppDelegate**:
- `@objc` action handlers with bodies (extract to a controller's `@objc` method)
- `Task { … }` blocks doing work (push the work into a service method)
- `NSMenu` / `NSMenuItem` construction (extract to a `XxxMenuController.install()`)
- `NSAlert` / `NSSavePanel` / `NSOpenPanel` flows (extract to the responsible controller)
- `observe { … }` / `withObservationTracking { … }` blocks (extract to a controller that owns the `ObserveToken`)
- Singleton bootstrapping logic, version checks, file I/O, log export — all belong to dedicated controllers

**The pattern** — every new lifecycle responsibility is a new `@MainActor` controller class in `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`, registered via the Singletons & Dependency Injection pattern above. Current examples:
- `AppearanceController` — observes `settings.general.appearance` and updates `NSApp.appearance`
- `DebugMenuController` — installs the Debug menu and owns the Export Logs flow
- `HelperServiceVersionChecker` — runs the helper version probe and presents reinstall alerts
- `UpdaterService` — owns the Sparkle updater lifecycle

AppDelegate then reduces to:

```swift
@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.appearanceController)         private var appearanceController
    @Dependency(\.debugMenuController)          private var debugMenuController
    @Dependency(\.helperServiceVersionChecker)  private var helperServiceVersionChecker
    @Dependency(\.mcpService)                   private var mcpService
    @Dependency(\.updaterService)               private var updaterService

    func applicationDidFinishLaunching(_ note: Notification) {
        NSToolbarItemViewerOverflowFix.install()
        appearanceController.start()
        debugMenuController.install()
        mcpService.start(for: AppMCPBridgeDocumentProvider())
        updaterService.start()
        helperServiceVersionChecker.checkOnLaunch()
    }

    func applicationWillTerminate(_ note: Notification) {
        updaterService.stop()
        mcpService.stop()
    }
}
```

If a lifecycle responsibility doesn't fit one of these one-liners, **make it a new controller before touching AppDelegate**.

### MVVM-C Completeness

**Every ViewController MUST have a corresponding ViewModel.** Never put business logic (service calls, state management, pasteboard operations) directly in the ViewController. The ViewController only handles:
- View setup and layout
- Firing relay events from `@objc` actions
- Binding ViewModel outputs to UI in `setupBindings(for:)`

### ViewController Base Class Selection

- **`AppKitViewController<VM>`**: Default choice for simple view controllers that don't need UXKit features (contentView, loading indicator, skeleton effects)
- **`UXKitViewController<VM>`**: Use when the ViewController needs `contentView` support, loading indicators (`CommonLoadingView`), or skeleton effects
- **`UXEffectViewController<VM>`**: Use when a visual effect background is needed (inherits `UXKitViewController`)

### UI Component Selection

**Always check for project wrapper types first** (from RuntimeViewerUI / UIFoundation). When a wrapper type cannot satisfy a specific need (e.g., `PushButton` has a fixed `.push` bezelStyle), fall back to the raw AppKit class (e.g., `NSButton()` for `.accessoryBarAction` bezelStyle).

**Private nested types for specialized views**: When a ViewController needs a custom view for a specific purpose, define it as a private nested type with namespace:
```swift
extension MyViewController {
    private class HeaderView: NSView { ... }
}
```

### ViewModel Conventions

**Base class**: All ViewModels inherit `ViewModel<Route>`, which provides `documentState`, `router`, `appDefaults`, `errorRelay`, `_commonLoading`.

**State properties** — use `@Observed` (NOT `BehaviorRelay`):
```swift
@Observed private(set) var currentPage: Page = .configuration
@Observed private(set) var nodes: [CellViewModel] = []
```
- Exposed as Driver/Signal via `$property.asDriver()` or `$property.asSignal()`
- Mutate by direct assignment: `currentPage = .progress`

**Input/Output transform pattern**:
```swift
@MemberwiseInit(.public)
struct Input {
    let cancelClick: Signal<Void>
    let searchString: Signal<String>
}

struct Output {
    let nodes: Driver<[CellViewModel]>        // State → Driver
    let requestSelection: Signal<Void>         // One-shot events → Signal
}

func transform(_ input: Input) -> Output {
    input.cancelClick.emitOnNext { [weak self] in
        guard let self else { return }
        router.trigger(.dismiss)
    }
    .disposed(by: rx.disposeBag)

    return Output(
        nodes: $nodes.asDriver(),
        requestSelection: requestSelectionRelay.asSignal()
    )
}
```

**One-shot events from ViewModel** — use `PublishRelay`:
```swift
private let requestDirectorySelectionRelay = PublishRelay<Void>()
```

**Dependency injection**: `@Dependency(\.appDefaults) var appDefaults`

### ViewController Conventions

**Base classes**: `AppKitViewController<VM>` (simple) or `UXKitViewController<VM>` (with contentView support).

**UI events** — prefer RxAppKit / RxCocoa `rx.*` accessors over hand-rolled `PublishRelay` + `@objc` action plumbing. Wire control events straight into `Input`:

```swift
let input = MyViewModel.Input(
    cancelClicked: cancelButton.rx.click.asSignal(),
    exportClicked: exportButton.rx.click.asSignal(),
    searchString: searchField.rx.stringValue.asSignal(onErrorJustReturn: "")
)
```

Common rx accessors to know:
- `NSButton`: `rx.click`, `rx.state`, `rx.title`, `rx.isEnabled`
- `NSSearchField` / `NSTextField`: `rx.stringValue`, `rx.text`
- `NSTableView`: `rx.itemClicked()`, `rx.itemSelected()`, `rx.modelSelected()`, `rx.items`, `rx.setDelegate(_:)`
- `NSOutlineView`: `rx.modelDoubleClicked()`, `rx.modelSelected()`, `rx.nodes`, `rx.reorderableNodes`
- `NSView`: `rx.isHidden` and friends

`PublishRelay<T>` is reserved for events that **cannot** be expressed as a control accessor:
- Aggregating clicks from dynamically rebuilt child views (e.g., per-row buttons in a form — see `SpecializationViewController.requestTypePickerClickedRelay`).
- One-shot events emitted by the ViewModel itself (returned to the controller via `Output`).

**Avoid**: `private let xxxRelay = PublishRelay<Void>()` + `@objc func xxxClicked()` + `xxxButton.target = self; xxxButton.action = #selector(...)` for a single, statically-known control. Replace it with `xxxButton.rx.click.asSignal()`.

**setupBindings pattern**:
```swift
override func setupBindings(for viewModel: MyViewModel) {
    super.setupBindings(for: viewModel)
    let input = MyViewModel.Input(cancelClick: cancelRelay.asSignal(), ...)
    let output = viewModel.transform(input)

    output.nodes.drive(outlineView.rx.nodes) { ... }.disposed(by: rx.disposeBag)

    output.currentPage.driveOnNext { [weak self] page in
        guard let self else { return }
        showPage(page)
    }
    .disposed(by: rx.disposeBag)
}
```

### UI Components

**Always use project wrapper types** (from RuntimeViewerUI / UIFoundation), NOT raw AppKit classes:

| Use | Instead of |
|-----|-----------|
| `Label()` / `Label("text")` | `NSTextField(labelWithString:)` |
| `PushButton()` | `NSButton()` |
| `ImageView()` | `NSImageView()` |
| `VStackView(alignment:spacing:) { ... }` | `NSStackView(orientation: .vertical)` |
| `HStackView(spacing:) { ... }` | `NSStackView(orientation: .horizontal)` |
| `ScrollView()` | `NSScrollView()` |
| `final class XxxView: LayerBackedView` | `final class XxxView: NSView` (when it needs `cornerRadius` / border / `backgroundColor` / shadow) |

**Layer-backed views** — any custom AppKit view that needs layer-level visuals (rounded corners, border, background color, shadow) MUST inherit `UIFoundationAppKit.LayerBackedView`, never raw `NSView` with hand-rolled `wantsLayer = true` + `layer?.cornerRadius / layer?.borderColor / layer?.backgroundColor = ....cgColor`. The base class already sets `wantsLayer + layerContentsRedrawPolicy = .onSetNeedsDisplay` and centralizes everything in `updateLayer()`, so:

- Assign the exposed `NSColor?` properties directly — `backgroundColor = NSColor(light:dark:)`, `borderColor = ...` — **without** `.cgColor`. Dynamic colors re-resolve on appearance change automatically; you do NOT need to override `viewDidChangeEffectiveAppearance`.
- One-time setup goes in `override func setup()` (called by `commonInit`); first-layout work goes in `override func firstLayout()`. Don't repeat `wantsLayer = true` in `init`.
- Available properties: `cornerRadius`, `borderWidth`, `borderColor`, `borderPositions`, `borderLocation`, `borderInsets`, `backgroundColor`, `shadowColor`, `shadowOpacity`, `shadowOffset`, `shadowRadius`, `shadowPath`.
- **Gotcha — `borderPositions` defaults to `[]`, so the border won't render** even with non-zero `borderWidth` + non-nil `borderColor`. To draw a full rounded border you MUST set `borderPositions = .all`:
  ```swift
  cornerRadius = 8
  borderWidth = 1
  borderColor = NSColor(light: ..., dark: ...)
  borderPositions = .all   // ← otherwise the previous 3 lines are ignored
  ```

**View initialization** — `.then {}` returns the configured object (for assignment):
```swift
let titleLabel = Label("Export").then {
    $0.font = .systemFont(ofSize: 18, weight: .semibold)
}
```

**View configuration** — `.do {}` mutates in place (for already-declared properties):
```swift
configRadioButton.do {
    $0.setButtonType(.radio)
    $0.title = "Single File"
    $0.state = .on
}
```

**Adding subviews** — use `hierarchy {}` result builder (NOT `addSubview`):
```swift
container.hierarchy {
    contentStack
    buttonStack
}
```

**Stack views** — use result builder initializer:
```swift
let contentStack = VStackView(alignment: .leading, spacing: 16) {
    headerStack
    imageNameStack
    formatStack
}

let buttonStack = HStackView(spacing: 8) {
    cancelButton
    exportButton
}
```

### Layout

**All layout uses SnapKit** — constraints grouped together after `hierarchy {}`:
```swift
container.hierarchy {
    contentStack
    buttonStack
}

contentStack.snp.makeConstraints { make in
    make.top.leading.trailing.equalToSuperview().inset(20)
}

buttonStack.snp.makeConstraints { make in
    make.trailing.bottom.equalToSuperview().inset(20)
}
```

### RxSwift Subscription Style

**Always use trailing-closure variants** (NOT `.emit(onNext:)` / `.drive(onNext:)` / `.subscribe(onNext:)` label syntax):

| Use (trailing closure) | Instead of (label syntax) |
|------------------------|--------------------------|
| `.emitOnNext { }` | `.emit(onNext: { })` |
| `.emitOnNextMainActor { }` | — |
| `.driveOnNext { }` | `.drive(onNext: { })` |
| `.driveOnNextMainActor { }` | — |
| `.subscribeOnNext { }` | `.subscribe(onNext: { })` |
| `.subscribeOnNextMainActor { }` | — |

```swift
// Signal
input.cancelClick.emitOnNext { [weak self] in
    guard let self else { return }
    router.trigger(.dismiss)
}
.disposed(by: rx.disposeBag)

// Driver
output.currentPage.driveOnNext { [weak self] page in
    guard let self else { return }
    showPage(page)
}
.disposed(by: rx.disposeBag)

// Observable
source.subscribeOnNext { [weak self] value in
    guard let self else { return }
    handleValue(value)
}
.disposed(by: rx.disposeBag)
```

For direct binding without closure logic, `.drive()` / `.bind(to:)` are fine:
```swift
output.imageName.drive(label.rx.stringValue).disposed(by: rx.disposeBag)
```

### NSTableView / NSOutlineView Rx Data Source

When a table or outline displays Rx-driven data, **always** use the `rx.items` / `rx.nodes` adapter. Never hand-roll an `NSTableViewDataSource` / `NSOutlineViewDataSource` (or pair `target` / `action` with manual cell-reuse code) for data already produced by an Rx pipeline.

**1. Table creation** — use the `scrollableTableView()` factory from UIFoundation:
```swift
private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()
```
For multi-column tables, use `NSTableView.scrollableTableView()` and add columns yourself. `SingleColumnTableView` already installs the default column.

**2. Items / nodes binding** — drive `tableView.rx.items` (or `outlineView.rx.nodes`) with the model driver and a cell-builder closure:
```swift
output.candidates
    .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, candidate: Candidate) -> NSView? in
        let cellView = tableView.box.makeView(ofClass: CandidateCellView.self)
        cellView.configure(with: candidate)
        return cellView
    }
    .disposed(by: rx.disposeBag)

output.nodes
    .drive(outlineView.rx.nodes) { (outlineView: NSOutlineView, _: NSTableColumn?, node: NodeViewModel) -> NSView? in
        let cellView = outlineView.box.makeView(ofClass: NodeCellView.self)
        cellView.bind(to: node)
        return cellView
    }
    .disposed(by: rx.disposeBag)
```

**3. Cell reuse** — use `tableView.box.makeView(ofClass:)` / `outlineView.box.makeView(ofClass:)` (UIFoundationToolbox). It handles identifier registration, recycling, and fresh instantiation transparently. **Never** write `tableView.makeView(withIdentifier:owner:) as? NSTableCellView` casts:
```swift
// ✅ Good
let cellView = tableView.box.makeView(ofClass: CandidateCellView.self)

// ❌ Bad
let cellView: NSTableCellView
if let recycled = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
    cellView = recycled
} else {
    cellView = NSTableCellView()
    cellView.identifier = identifier
    // … manual subview wiring …
}
```
Pass a custom builder when the cell needs non-default initialization: `outlineView.box.makeView(ofClass: SidebarRuntimeObjectCellView.self) { .init(forOpenQuickly: false) }`.

**4. Cell view definition** — declare cell views as `fileprivate final class` nested inside a controller extension, inheriting `TableCellView` (UIFoundationAppKit) so `setup()` and the auto-set identifier come for free. Use `bind(to:)` with reactive bindings (`rx.disposeBag = DisposeBag()` first to drop the previous row's bindings). Reserve `configure(with:)` only for purely-static cells with no `@Observed` properties on the cell ViewModel:
```swift
extension MyViewController {
    fileprivate final class CandidateCellView: TableCellView {
        private let nameLabel = Label()

        override func setup() {
            super.setup()

            hierarchy {
                nameLabel
            }
            nameLabel.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview().inset(4)
                make.centerY.equalToSuperview()
            }
            nameLabel.maximumNumberOfLines = 1
        }

        func bind(to viewModel: CandidateCellViewModel) {
            rx.disposeBag = DisposeBag()

            viewModel.$name.asDriver().drive(nameLabel.rx.attributedStringValue).disposed(by: rx.disposeBag)
            viewModel.$icon.asDriver().drive(iconImageView.rx.image).disposed(by: rx.disposeBag)
        }
    }
}
```

**5. Cell ViewModel wrapper** — wrap each row's domain model in a per-cell `XxxCellViewModel` (à la `SidebarRuntimeObjectCellViewModel`, `SidebarRootCellViewModel`, `InspectorSwiftSpecializationCellViewModel`). Place it under the relevant `RuntimeViewerApplication` subfolder, declare it `public final class … : NSObject, @unchecked Sendable`, hold the underlying model as a stored `let`, and expose every piece of display state (icons, attributed names, filter results) as `@Observed public private(set) var` so the cell view can drive its UI off the projected `$property` driver in `bind(to:)`. The `Input` / `Output` of the parent `ViewModel` should traffic in `XxxCellViewModel`, not the raw model.

```swift
public final class CandidateCellViewModel: NSObject, @unchecked Sendable {
    public let candidate: Candidate

    @Observed
    public private(set) var name: NSAttributedString

    @Observed
    public private(set) var icon: NSUIImage?

    public init(candidate: Candidate) {
        self.candidate = candidate
        self.name = NSAttributedString {
            AText(candidate.displayName)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
        }
        self.icon = candidate.icon
        super.init()
    }
}
```

**6. Differentiable conformance** — every model used by `rx.items` / `rx.nodes` must conform to `Differentiable` (DifferenceKit). Conform the **cell ViewModel**, not the raw domain type — never write `extension RuntimeObject: @retroactive Differentiable {}` on a core type, since retroactive conformances on shared models risk collisions across modules. Pick `differenceIdentifier` so it stays stable across rebuilds (typically the underlying domain object or its id), and gate the conformance behind `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` like Sidebar does:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension XxxCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObject { runtimeObject }
    public func isContentEqual(to source: XxxCellViewModel) -> Bool {
        runtimeObject == source.runtimeObject
    }
}
#endif
```
For cell ViewModels that own no extra state beyond the underlying `Hashable` domain object, an empty `extension XxxCellViewModel: Differentiable {}` is acceptable — DifferenceKit synthesizes `differenceIdentifier = self` / `isContentEqual = ==` from `Hashable + Equatable`.

**7. Click / selection events** — derive from `tableView.rx.itemClicked()` / `tableView.rx.modelSelected()` / `outlineView.rx.modelDoubleClicked()` instead of `target` + `@objc` plumbing:
```swift
let rowClicked: Signal<Candidate> = tableView.rx
    .itemClicked()
    .compactMap { [weak tableView] index -> Candidate? in
        guard let tableView,
              index.row >= 0,
              index.row < tableView.numberOfRows
        else { return nil }
        return try? tableView.rx.model(at: index.row)
    }
    .asSignal(onErrorSignalWith: .empty())
```

**8. Optional delegate methods** — when you need optional `NSTableViewDelegate` / `NSOutlineViewDelegate` callbacks (`shouldSelectRow`, persistence helpers, etc.), forward them via `tableView.rx.setDelegate(self)` / `outlineView.rx.setDelegate(delegate)` and implement those methods in an extension. The `rx.items` / `rx.nodes` adapter owns the data source and required-method delegate proxy and forwards optional methods through to the delegate you set.

**9. Lazy Cell ViewModel for large data sets** — for data sets where eager per-row `cellViewModel` allocation dominates main-thread time (N >= ~1k rows, popovers/pickers over global type/symbol indexes, etc.), drive `rx.items` / `rx.nodes` with `DifferentiableBox<Model>` (from `RuntimeViewerArchitectures`) instead of a `[XxxCellViewModel]`, and construct the cellViewModel lazily inside the cell builder closure. The wrapper is a value-type box that adapts any `Hashable` domain model to DifferenceKit's `Differentiable` protocol so the driver array carries cheap identity elements rather than fully-built cellViewModels.

**Eligibility decision tree** — pick lazy mode iff **all three** are true; otherwise stay on the eager 1:1 cellViewModel pattern above:

1. The cellViewModel's state is *fully determined at init time* from the model alone — no `@Observed` properties that mutate after init, no Rx pipelines fed by external sources, no `Task { … }` async loading inside the cellVM.
2. The data set is large enough that eager construction is visible in Instruments (typically N >= 1k, confirmed by a signpost baseline).
3. There is no per-row UI state that cannot be derived from the model (expanded/collapsed flag, multi-select checkmark, drag-preview metadata). If you need such state, build a local `struct` conforming to `Differentiable` directly — do NOT add mutable fields onto `DifferentiableBox`.

Sidebar / Inspector cellViewModels (e.g. `SidebarRuntimeObjectCellViewModel`, `InspectorSwiftSpecializationCellViewModel`) own filter-aware attributed names or async metadata loading, so they must stay eager — lazy reconstruction would drop their subscription identity. The `SpecializationTypePicker` popover is the canonical lazy case (10k+ candidates when a generic parameter has no constraint).

```swift
// ViewModel — driver element is a value-type identity box, not the cellViewModel
typealias CandidateBox = DifferentiableBox<RuntimeSpecializationRequest.Candidate>

@Observed
public private(set) var filteredRows: [CandidateBox] = []

public init(candidates: [RuntimeSpecializationRequest.Candidate], ...) {
    self.allRows = candidates.sorted().map(CandidateBox.init)
    super.init(...)
    self.filteredRows = allRows
}

// ViewController — cellViewModel built lazily, only for cells the table renders
output.filteredRows
    .drive(tableView.rx.items) { (tableView, _, _, row: CandidateBox) -> NSView? in
        let cellView = tableView.box.makeView(ofClass: SomeCellView.self)
        let cellViewModel = SpecializationTypePickerCellViewModel(candidate: row.model)
        cellView.bind(to: cellViewModel)
        return cellView
    }
    .disposed(by: rx.disposeBag)
```

`DifferentiableBox<Model>.differenceIdentifier == model`, so DifferenceKit treats two boxes as the same row iff their underlying models are `==`. Pick `Model`'s `Equatable` carefully — equality fields should be a stable domain primary key, not include presentation-only data, otherwise the diff will spuriously trigger updates. `DifferentiableBox` itself is fully `Hashable` even on UIKit / Catalyst; the `Differentiable` conformance is gated behind `#if canImport(AppKit) && !targetEnvironment(macCatalyst)`.

### Closures & Self Capture

**Always** use `guard let self else { return }` (NOT `strongSelf`, NOT `if let self`):
```swift
output.result.driveOnNext { [weak self] value in
    guard let self else { return }
    handleResult(value)
}
.disposed(by: rx.disposeBag)
```

### Coordinator Conventions

**Route enums** — use `@AssociatedValue` and `@CaseCheckable` macros:
```swift
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum MyRoute: Routable {
    case root
    case detail(RuntimeObject)
    case dismiss
}
```

**ViewController creation** — always in Coordinator's `prepareTransition`, not in ViewController:
```swift
override func prepareTransition(for route: MainRoute) -> MainTransition {
    case .exportInterfaces:
        let viewController = ExportingViewController()
        let viewModel = ExportingViewModel(documentState: documentState, router: self)
        viewController.setupBindings(for: viewModel)
        return .presentOnRoot(viewController, mode: .asSheet)
}
```

**Delegate pattern** — nested protocol inside Coordinator, implemented by parent Coordinator:
```swift
// In child
protocol Delegate: AnyObject {
    func sidebarCoordinator(_ coordinator: SidebarCoordinator, completeTransition route: SidebarRoute)
}
weak var delegate: Delegate?

// In parent
extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(_ coordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route { ... }
    }
}
```

### MARK Groups

Organize ViewController code with `// MARK: -` sections:
```
// MARK: - Relays
// MARK: - Configuration Page  (or other UI sections)
// MARK: - Lifecycle
// MARK: - Actions
// MARK: - Page Management
// MARK: - Bindings
```

### Error Handling

Use base class `errorRelay` — ViewController base class auto-presents alerts:
```swift
// In ViewModel
errorRelay.accept(error)

// In async context
do { ... } catch {
    await MainActor.run { self.errorRelay.accept(error) }
}
```

### Platform Requirements

- Swift 6.2, Xcode 15+
- RuntimeViewerCore: macOS 10.15+, iOS 13+, macCatalyst 13+, watchOS 6+, tvOS 13+, visionOS 1+
- RuntimeViewerPackages: macOS 15+, iOS 18+, macCatalyst 18+, tvOS 18+, visionOS 2+
- RuntimeViewerMCP: macOS 15+

## Documentation

- Design documents and implementation plans: `Documentations/Plans/`
- Evolution proposals: `Documentations/Evolution/`

## Key Source Locations

- Main app entry: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`
- Document model: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift`
- Coordinator/navigation: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`
- Runtime engine: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`
- Document state: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/DocumentState.swift`
- ViewModels: `RuntimeViewerPackages/Sources/RuntimeViewerApplication/`
- MCP bridge window provider: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppMCPBridgeWindowProvider.swift`
- MCP server: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/`
- MCP bridge: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/`

## MCP Tool Preferences

When MCP servers are available, **MUST** prefer them over shell commands and built-in tools:

### Xcode MCP (Project Operations)
Prefer Xcode MCP tools for all Xcode project-level operations:
- **File reading**: Use `XcodeRead` instead of `Read` / `cat` for files in the Xcode project
- **File writing**: Use `XcodeWrite` instead of `Write` for creating/overwriting files in the project
- **File editing**: Use `XcodeUpdate` instead of `Edit` / `sed` for modifying files in the project
- **File searching**: Use `XcodeGrep` instead of `Grep` / `grep` for searching in project files
- **File discovery**: Use `XcodeGlob` / `XcodeLS` instead of `Glob` / `ls` for browsing project structure
- **File management**: Use `XcodeMakeDir`, `XcodeMV`, `XcodeRM` for directory/file operations
- **Build**: Use `BuildProject` for building the project through Xcode
- **Tests**: Use `GetTestList`, `RunSomeTests`, `RunAllTests` for test operations
- **Diagnostics**: Use `XcodeRefreshCodeIssuesInFile`, `XcodeListNavigatorIssues` for checking issues
- **Preview**: Use `RenderPreview` for SwiftUI preview rendering
- **Snippets**: Use `ExecuteSnippet` for running code snippets in project context
- **Documentation**: Use `DocumentationSearch` for searching Apple Developer Documentation

### Priority Order
1. **Xcode MCP** — for project file operations, in-editor builds, diagnostics, and previews
2. **Built-in tools** — fallback when MCP tools are unavailable or not applicable

## External Dependencies

Core reverse engineering powered by:
- [MachOKit](https://github.com/MxIris-Reverse-Engineering/MachOKit) — Mach-O binary parsing
- [MachOObjCSection](https://github.com/MxIris-Reverse-Engineering/MachOObjCSection) — ObjC runtime introspection
- [MachOSwiftSection](https://github.com/MxIris-Reverse-Engineering/MachOSwiftSection) — Swift interface extraction
- [MachInjector](https://github.com/MxIris-Reverse-Engineering/MachInjector) — Code injection (requires SIP disabled)

Key libraries:
- [RxSwift](https://github.com/ReactiveX/RxSwift) ecosystem (RxSwift, RxCocoa, RxCombine, RxSwiftPlus, RxAppKit)
- [CocoaCoordinator](https://github.com/Mx-Iris/CocoaCoordinator) (macOS) / [XCoordinator](https://github.com/MxIris-Library-Forks/XCoordinator) (iOS)
- [swift-dependencies](https://github.com/pointfreeco/swift-dependencies) — Dependency injection
- [swift-navigation](https://github.com/MxIris-Library-Forks/swift-navigation) — Navigation and observation
