# MCP Toolbar Status Indicator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Display MCP server status (disabled/stopped/running) in the main window toolbar with a colored icon and a popover showing details and controls.

**Architecture:** MCPService becomes a singleton with observable state (`onStateChange` callback). A new toolbar item displays a colored antenna icon. Clicking it opens an NSPopover with server info, port copy, and start/stop/settings controls.

**Tech Stack:** AppKit, RxSwift (BehaviorRelay for toolbar binding), SnapKit, RuntimeViewerUI components, RuntimeViewerMCPBridge (MCPService)

---

### Task 1: Add observable state to MCPService

**Files:**
- Modify: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/MCPService.swift`

**Step 1: Add MCPServerState enum and state properties**

Add before the `MCPService` class:

```swift
public enum MCPServerState: Equatable, Sendable {
    case disabled
    case stopped
    case running(port: UInt16)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var port: UInt16? {
        if case .running(let port) = self { return port }
        return nil
    }
}
```

**Step 2: Add singleton, state property, and callback to MCPService**

In `MCPService`, replace `public init()` and add:

```swift
public static let shared = MCPService()

public private(set) var serverState: MCPServerState = .stopped {
    didSet {
        guard oldValue != serverState else { return }
        onStateChange?(serverState)
    }
}

public var onStateChange: ((MCPServerState) -> Void)?
```

Change `public init()` to `private init()`.

**Step 3: Update start() to set serverState**

In `start(for:)`, after `logger.info("MCP HTTP+SSE server listening on port \\(boundPort)")`, add:

```swift
self.serverState = .running(port: boundPort)
```

In the `catch` block, add:

```swift
self.serverState = .stopped
```

**Step 4: Update stop() to set serverState**

In `stop()`, after clearing transport/tasks, add:

```swift
let isEnabled = settings.mcp.isEnabled
serverState = isEnabled ? .stopped : .disabled
```

**Step 5: Update observe() to handle isEnabled changes**

In `observe()`, inside the `if enabledChanged || portChanged` block, before `scheduleRestart`:

When `!isMCPEnabled`, set state immediately:

```swift
if !isMCPEnabled {
    serverState = .disabled
}
```

**Step 6: Set initial state in start()**

At the very beginning of `start(for:)`, before the Task:

```swift
let mcpSettings = settings.mcp
guard mcpSettings.isEnabled else {
    serverState = .disabled
    return
}
```

**Step 7: Commit**

```
feat: add observable state to MCPService with singleton pattern
```

---

### Task 2: Update AppDelegate to use MCPService.shared

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`

**Step 1: Replace private instance with shared singleton**

Replace:
```swift
private var mcpService: MCPService?
```
with nothing (remove the property).

Replace in `applicationDidFinishLaunching`:
```swift
mcpService = MCPService().then {
    $0.start(for: AppMCPBridgeDocumentProvider())
}
```
with:
```swift
MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
```

Replace in `applicationWillTerminate`:
```swift
mcpService?.stop()
```
with:
```swift
MCPService.shared.stop()
```

Remove `extension MCPService: Then {}` (no longer needed).

**Step 2: Commit**

```
refactor: use MCPService.shared singleton in AppDelegate
```

---

### Task 3: Add MCPStatusToolbarItem to MainToolbarController

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift`

**Step 1: Add toolbar item identifier**

In `NSToolbarItem.Identifier.Main`, add:

```swift
static let mcpStatus: NSToolbarItem.Identifier = "mcpStatus"
```

**Step 2: Add MCPStatusToolbarItem class**

Inside `MainToolbarController`, add a new nested class:

```swift
class MCPStatusToolbarItem: NSToolbarItem {
    let button = ToolbarButton()

    init() {
        super.init(itemIdentifier: .Main.mcpStatus)
        view = button
        button.title = ""
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryPushIn)
        updateAppearance(for: .stopped)
    }

    func updateAppearance(for state: MCPServerState) {
        switch state {
        case .disabled:
            button.image = SFSymbols(.init(rawValue: "antenna.radiowaves.left.and.right.slash")).nsImage
            button.contentTintColor = .systemGray
        case .stopped:
            button.image = SFSymbols(.init(rawValue: "antenna.radiowaves.left.and.right.slash")).nsImage
            button.contentTintColor = .systemRed
        case .running:
            button.image = SFSymbols(.init(rawValue: "antenna.radiowaves.left.and.right")).nsImage
            button.contentTintColor = .systemGreen
        }
    }
}
```

Note: `MCPServerState` is from `RuntimeViewerMCPBridge`, so `MainToolbarController.swift` needs `import RuntimeViewerMCPBridge`.

**Step 3: Add mcpStatusItem property**

```swift
let mcpStatusItem = MCPStatusToolbarItem().then {
    $0.label = "MCP Status"
}
```

**Step 4: Add to toolbar layout**

In `toolbarDefaultItemIdentifiers`, insert `.Main.mcpStatus` before `.inspectorTrackingSeparator`:

```swift
.Main.share,
.Main.mcpStatus,     // <-- new
.inspectorTrackingSeparator,
```

In `toolbarAllowedItemIdentifiers`, add `.Main.mcpStatus`.

In `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`, add case:

```swift
case .Main.mcpStatus:
    return mcpStatusItem
```

**Step 5: Commit**

```
feat: add MCP status toolbar item with colored antenna icon
```

---

### Task 4: Create MCPStatusPopoverController

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MCPStatusPopoverController.swift`

This is a plain NSViewController (not MVVM — it's a simple status display, not a document-level feature). It directly observes MCPService.shared.

```swift
import AppKit
import RuntimeViewerUI
import RuntimeViewerMCPBridge
import RuntimeViewerSettingsUI

final class MCPStatusPopoverController: NSViewController {

    // MARK: - Views

    private let statusCircle = ImageView()
    private let statusLabel = Label()
    private let portTitleLabel = Label("Port:")
    private let portValueLabel = Label()
    private let copyPortButton = PushButton()
    private let actionButton = PushButton()
    private let containerStack = VStackView(alignment: .leading, spacing: 12) {}

    // MARK: - State

    private var currentState: MCPServerState = .stopped

    // MARK: - Lifecycle

    override func loadView() {
        view = UXView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupViews()
        setupLayout()
        updateUI(for: MCPService.shared.serverState)

        MCPService.shared.onStateChange = { [weak self] state in
            guard let self else { return }
            updateUI(for: state)
        }
    }

    // MARK: - Setup

    private func setupViews() {
        statusCircle.do {
            $0.imageScaling = .scaleProportionallyDown
        }

        statusLabel.do {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textColor = .labelColor
        }

        portTitleLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        portValueLabel.do {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            $0.textColor = .labelColor
        }

        copyPortButton.do {
            $0.image = SFSymbols(.init(rawValue: "doc.on.doc")).nsImage
            $0.bezelStyle = .accessoryBarAction
            $0.isBordered = true
            $0.toolTip = "Copy Port"
            $0.target = self
            $0.action = #selector(copyPort)
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }

        actionButton.do {
            $0.bezelStyle = .push
            $0.controlSize = .regular
            $0.target = self
            $0.action = #selector(actionButtonClicked)
        }
    }

    private func setupLayout() {
        let statusRow = HStackView(spacing: 6) {
            statusCircle
            statusLabel
        }

        let portRow = HStackView(spacing: 6) {
            portTitleLabel
            portValueLabel
            copyPortButton
        }

        let contentStack = VStackView(alignment: .leading, spacing: 10) {
            statusRow
            portRow
            actionButton
        }

        view.hierarchy {
            contentStack
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        }

        statusCircle.snp.makeConstraints { make in
            make.size.equalTo(10)
        }

        actionButton.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(120)
        }
    }

    // MARK: - UI Update

    private func updateUI(for state: MCPServerState) {
        currentState = state

        switch state {
        case .disabled:
            statusCircle.contentTintColor = .systemGray
            statusCircle.image = SFSymbols(.init(rawValue: "circle.fill")).nsImage
            statusLabel.stringValue = "MCP Server Disabled"
            portTitleLabel.isHidden = true
            portValueLabel.isHidden = true
            copyPortButton.isHidden = true
            actionButton.title = "Open Settings…"

        case .stopped:
            statusCircle.contentTintColor = .systemRed
            statusCircle.image = SFSymbols(.init(rawValue: "circle.fill")).nsImage
            statusLabel.stringValue = "MCP Server Stopped"
            portTitleLabel.isHidden = true
            portValueLabel.isHidden = true
            copyPortButton.isHidden = true
            actionButton.title = "Start Server"

        case .running(let port):
            statusCircle.contentTintColor = .systemGreen
            statusCircle.image = SFSymbols(.init(rawValue: "circle.fill")).nsImage
            statusLabel.stringValue = "MCP Server Running"
            portTitleLabel.isHidden = false
            portValueLabel.isHidden = false
            portValueLabel.stringValue = "\(port)"
            copyPortButton.isHidden = false
            actionButton.title = "Stop Server"
        }
    }

    // MARK: - Actions

    @objc private func copyPort() {
        guard let port = currentState.port else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(port)", forType: .string)
    }

    @objc private func actionButtonClicked() {
        switch currentState {
        case .disabled:
            SettingsWindowController.shared.showWindow(nil)
        case .stopped:
            MCPService.shared.start(for: AppMCPBridgeDocumentProvider())
        case .running:
            MCPService.shared.stop()
        }
    }
}
```

**Commit:**

```
feat: add MCP status popover with server info and controls
```

---

### Task 5: Wire up popover in MainWindowController

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift`

**Step 1: Add popover and state relay**

Add properties:

```swift
private lazy var mcpPopover: NSPopover = {
    let popover = NSPopover()
    popover.contentViewController = MCPStatusPopoverController()
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 260, height: 100)
    return popover
}()
```

**Step 2: Add MCP toolbar bindings in setupBindings**

At the end of `setupBindings(for:)`, add:

```swift
// MCP Status toolbar item
toolbarController.mcpStatusItem.button.rx.click.asSignal()
    .emitOnNext { [weak self] in
        guard let self else { return }
        let button = toolbarController.mcpStatusItem.button
        mcpPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    .disposed(by: rx.disposeBag)

// Update toolbar icon when MCP state changes
let mcpStateRelay = BehaviorRelay<MCPServerState>(value: MCPService.shared.serverState)
MCPService.shared.onStateChange = { state in
    mcpStateRelay.accept(state)
}
mcpStateRelay.asDriver()
    .driveOnNext { [weak self] state in
        guard let self else { return }
        toolbarController.mcpStatusItem.updateAppearance(for: state)
    }
    .disposed(by: rx.disposeBag)
```

Add `import RuntimeViewerMCPBridge` to the file.

**Step 3: Commit**

```
feat: wire MCP status toolbar item with popover and state updates
```

---

### Task 6: Build and verify

**Step 1: Build the project**

Build RuntimeViewerMCPBridge first to verify MCPServerState compiles:

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerMCP && swift build
```

Then build the full app via Xcode MCP `BuildProject`.

**Step 2: Fix any compilation errors**

Common issues to watch for:
- `SFSymbols` initialization — if `.init(rawValue:)` doesn't work, check the actual API in RuntimeViewerUI
- `ToolbarButton` configuration — may need specific setup for `contentTintColor`
- `MCPService.shared.start(for:)` requires `AppMCPBridgeDocumentProvider` which is in the app target — popover restart needs this

**Step 3: Commit**

```
feat: MCP toolbar status indicator with popover controls
```
