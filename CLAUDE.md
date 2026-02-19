# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Runtime Viewer is a macOS/iOS document-based (NSDocument) application for inspecting Objective-C and Swift runtime interfaces. It serves as a modern alternative to RuntimeBrowser with features like Swift interface support, type-defined jumps, Xcode-style syntax highlighting, code injection capabilities, and MCP (Model Context Protocol) integration for LLM clients.

## Build Commands

```bash
# Debug build (x86_64 and arm64e)
./BuildScript.sh

# Or directly via xcodebuild (debug scheme)
xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS'

# Release archive (builds Catalyst helper first, then main app, with notarization)
# Uses scheme "RuntimeViewer macOS"
./ArchiveScript.sh

# Build RuntimeViewerServer XCFramework (all platforms)
./BuildRuntimeViewerServerXCFramework.sh
```

**Build Schemes**:
- `RuntimeViewerUsingAppKit` — Debug builds
- `RuntimeViewer macOS` — Release archives

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

## Code Style

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

**UI events** — use `PublishRelay` at the top, fire from `@objc` actions:
```swift
private let cancelRelay = PublishRelay<Void>()
private let exportRelay = PublishRelay<Void>()

@objc private func cancelClicked() {
    cancelRelay.accept(())
}
```

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
