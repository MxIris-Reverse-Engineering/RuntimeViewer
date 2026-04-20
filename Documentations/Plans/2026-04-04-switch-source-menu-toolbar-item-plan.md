# Switch Source: NSMenuToolbarItem Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the NSPopUpButton-based switch source toolbar item with NSMenuToolbarItem, decoupling the displayed title/image from menu contents so disconnected engines show a "(Disconnected)" indicator without forcing a UI switch.

**Architecture:** NSMenuToolbarItem manages its own `title`/`image` independently of its `menu`. MainViewModel derives a `SwitchSourceState` by combining `selectedEngineIdentifier` with `runtimeEngineSections` — when the selected engine disappears from sections, the state transitions to disconnected with cached display info. RxAppKit gets a new `NSMenuToolbarItem+Rx.swift` with a `sectionItems` binder and `menuItemClick` event.

**Tech Stack:** AppKit (NSMenuToolbarItem), RxSwift/RxCocoa, RxAppKit

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `RxAppKit/.../Components/NSMenuToolbarItem+Rx.swift` | Create | sectionItems binder + menuItemClick ControlEvent |
| `MainToolbarController.swift` | Modify (lines 125–134) | SwitchSourceToolbarItem → NSMenuToolbarItem subclass |
| `MainViewModel.swift` | Modify | Add SwitchSourceState, derive from sections + selectedID, cache display info |
| `MainWindowController.swift` | Modify (lines 98–176) | Update bindings for menu content, toolbar display, menu click |

---

### Task 1: Add NSMenuToolbarItem+Rx.swift to RxAppKit

**Files:**
- Create: `/Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit/Sources/RxAppKit/Components/NSMenuToolbarItem+Rx.swift`

This task adds two Rx extensions on `NSMenuToolbarItem`:
1. A `sectionItems` `Binder` that rebuilds the toolbar item's menu from `([Section], AnyHashable?)` data (sections + selected identifier), with section headers and `.on` state for the selected item.
2. A `menuItemClick` `ControlEvent` that emits the `representedObject` of clicked menu items.

The binder element type is `([Section], AnyHashable?)` — a tuple of sections and selected represented object. This allows `Driver.combineLatest` at the call site to re-trigger the binder when either sections or selection changes.

- [ ] **Step 1: Create NSMenuToolbarItem+Rx.swift**

Create the file at `/Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit/Sources/RxAppKit/Components/NSMenuToolbarItem+Rx.swift`:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RxSwift
import RxCocoa

@available(macOS 14.0, *)
extension Reactive where Base: NSMenuToolbarItem {
    /// Binds section-grouped items to a menu toolbar item using NSMenuItem.sectionHeader.
    ///
    /// The binder element is `([Section], AnyHashable?)` — sections and the selected item's
    /// representedObject. Sets `state = .on` on the menu item matching the selected value.
    ///
    /// Usage with `Driver.combineLatest`:
    /// ```
    /// Driver.combineLatest(sectionsDriver, selectedIDDriver)
    ///     .drive(toolbarItem.rx.sectionItems(
    ///         sectionTitle: { $0.name },
    ///         items: { $0.items },
    ///         ...
    ///     ))
    /// ```
    public func sectionItems<Section, Item>(
        sectionTitle: @escaping (Section) -> String,
        items: @escaping (Section) -> [Item],
        itemTitle: @escaping (Item) -> String,
        itemImage: ((Item) -> NSImage?)? = nil,
        itemRepresentedObject: @escaping (Item) -> AnyHashable,
        configureMenuItem: ((NSMenuItem, Item) -> Void)? = nil
    ) -> Binder<([Section], AnyHashable?)> {
        Binder(base) { toolbarItem, value in
            let (sections, selectedRepresentedObject) = value
            let menu = toolbarItem.menu ?? NSMenu()

            menu.removeAllItems()

            let proxy = toolbarItem.rx.menuProxy

            for section in sections {
                let header = NSMenuItem.sectionHeader(title: sectionTitle(section))
                menu.addItem(header)

                for item in items(section) {
                    let representedObject = itemRepresentedObject(item)
                    let menuItem = NSMenuItem(title: itemTitle(item), action: #selector(proxy.run(_:)), keyEquivalent: "")
                    menuItem.target = proxy
                    menuItem.image = itemImage?(item)
                    menuItem.representedObject = representedObject
                    if let selectedRepresentedObject, representedObject == selectedRepresentedObject {
                        menuItem.state = .on
                    }
                    configureMenuItem?(menuItem, item)
                    menu.addItem(menuItem)
                }
            }

            toolbarItem.menu = menu
        }
    }

    /// Emits the representedObject of the clicked menu item.
    public func menuItemClick<T: Hashable>(_ type: T.Type = T.self) -> ControlEvent<T?> {
        let source = menuProxy.didSelectItem.map { $0.1 as? T }
        return ControlEvent(events: source)
    }

    fileprivate var menuProxy: RxNSMenuToolbarItemProxy {
        associatedValue { _ in RxNSMenuToolbarItemProxy() }
    }
}

/// Action trampoline for NSMenuToolbarItem menu item clicks.
class RxNSMenuToolbarItemProxy: NSObject {
    let didSelectItem = PublishRelay<(NSMenuItem, Any?)>()

    @objc func run(_ menuItem: NSMenuItem) {
        didSelectItem.accept((menuItem, menuItem.representedObject))
    }
}

#endif
```

- [ ] **Step 2: Verify RxAppKit builds**

```bash
cd /Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit && swift build 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Repositories/Private/Personal/Library/macOS/RxAppKit
git add Sources/RxAppKit/Components/NSMenuToolbarItem+Rx.swift
git commit -m "feat: add NSMenuToolbarItem+Rx with sectionItems binder and menuItemClick event"
```

---

### Task 2: Refactor SwitchSourceToolbarItem to NSMenuToolbarItem

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift` (lines 125–134)

- [ ] **Step 1: Replace SwitchSourceToolbarItem implementation**

Replace the existing class (lines 125–134):

```swift
class SwitchSourceToolbarItem: NSToolbarItem {
    let popUpButton = NSPopUpButton()

    init() {
        super.init(itemIdentifier: .Main.switchSource)
        view = popUpButton
        popUpButton.controlSize = .large
        popUpButton.bezelStyle = .toolbar
    }
}
```

With:

```swift
class SwitchSourceToolbarItem: NSMenuToolbarItem {
    init() {
        super.init(itemIdentifier: .Main.switchSource)
        showsIndicator = true
        isBordered = true
        menu = NSMenu()
    }

    var displayTitle: String {
        get { title }
        set { title = newValue }
    }

    var displayImage: NSImage? {
        get { image }
        set { image = newValue }
    }
}
```

- [ ] **Step 2: Commit (project won't build yet — MainWindowController still references popUpButton)**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainToolbarController.swift
git commit -m "refactor: change SwitchSourceToolbarItem from NSPopUpButton to NSMenuToolbarItem"
```

---

### Task 3: Add SwitchSourceState and ViewModel Logic

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift`

- [ ] **Step 1: Add SwitchSourceState struct above MainViewModel class**

Insert after the `SharingData` struct (after line 23):

```swift
struct SwitchSourceState: Equatable {
    let title: String
    let image: NSImage?
    let isDisconnected: Bool
    let selectedEngineIdentifier: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.isDisconnected == rhs.isDisconnected
            && lhs.selectedEngineIdentifier == rhs.selectedEngineIdentifier
            && lhs.image === rhs.image
    }
}
```

- [ ] **Step 2: Add cached display properties and icon resolver to MainViewModel**

Add after the `selectedEngineIdentifier` relay (after line 68):

```swift
private var cachedSelectedEngineName: String = RuntimeEngine.local.source.description

private var cachedSelectedEngineImage: NSImage?

private func resolveEngineIcon(for engine: RuntimeEngine) -> NSImage? {
    switch engine.source {
    case .local:
        return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
    case .remote(_, let identifier, _) where identifier == .macCatalyst:
        return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
    default:
        if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
            return runtimeEngineManager.cachedIcon(for: engine) ?? .symbol(name: RuntimeViewerSymbols.appFill)
        } else {
            let fallback = engine.hostInfo.metadata.isSimulator
                ? NSWorkspace.shared.box.deviceSymbolIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
                : NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
            return runtimeEngineManager.cachedIcon(for: engine) ?? fallback
        }
    }
}
```

- [ ] **Step 3: Update Output struct — replace selectedEngineIdentifier with switchSourceState**

In the `Output` struct (line 49), replace:

```swift
let selectedEngineIdentifier: Driver<String>
```

With:

```swift
let switchSourceState: Driver<SwitchSourceState>
```

- [ ] **Step 4: Update input.switchSource handler to cache display info**

Replace the existing handler (lines 161–167):

```swift
input.switchSource.compactMap { $0 }.emit(with: self) { owner, identifier in
    guard let engine = owner.runtimeEngineManager.runtimeEngines.first(where: {
        $0.engineID == identifier
    }) else { return }
    owner.router.trigger(.main(engine))
    owner.selectedEngineIdentifier.accept(identifier)
}.disposed(by: rx.disposeBag)
```

With:

```swift
input.switchSource.compactMap { $0 }.emit(with: self) { owner, identifier in
    guard let engine = owner.runtimeEngineManager.runtimeEngines.first(where: {
        $0.engineID == identifier
    }) else { return }
    owner.cachedSelectedEngineName = engine.source.description
    owner.cachedSelectedEngineImage = owner.resolveEngineIcon(for: engine)
    owner.router.trigger(.main(engine))
    owner.selectedEngineIdentifier.accept(identifier)
}.disposed(by: rx.disposeBag)
```

- [ ] **Step 5: Add switchSourceState derivation before the return Output block**

Insert before `return Output(...)` (before line 194):

```swift
let switchSourceState = Driver.combineLatest(
    runtimeEngineManager.rx.runtimeEngineSections,
    selectedEngineIdentifier.asDriver()
).map { [weak self] sections, selectedIdentifier -> SwitchSourceState in
    guard let self else {
        return SwitchSourceState(title: "RuntimeViewer", image: nil, isDisconnected: true, selectedEngineIdentifier: selectedIdentifier)
    }
    let allEngines = sections.flatMap(\.engines)
    if let engine = allEngines.first(where: { $0.engineID == selectedIdentifier }) {
        let name = engine.source.description
        let image = resolveEngineIcon(for: engine)
        cachedSelectedEngineName = name
        cachedSelectedEngineImage = image
        return SwitchSourceState(
            title: name,
            image: image,
            isDisconnected: false,
            selectedEngineIdentifier: selectedIdentifier
        )
    } else {
        return SwitchSourceState(
            title: cachedSelectedEngineName + " (Disconnected)",
            image: cachedSelectedEngineImage,
            isDisconnected: true,
            selectedEngineIdentifier: selectedIdentifier
        )
    }
}
```

- [ ] **Step 6: Update return Output — replace selectedEngineIdentifier with switchSourceState**

In the `return Output(...)` block, replace:

```swift
selectedEngineIdentifier: selectedEngineIdentifier.asDriver(),
```

With:

```swift
switchSourceState: switchSourceState,
```

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainViewModel.swift
git commit -m "feat: add SwitchSourceState with disconnection detection and display info caching"
```

---

### Task 4: Update MainWindowController Bindings

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift` (lines 98–176)

- [ ] **Step 1: Replace switchSource input signal**

In `setupBindings(for:)`, replace line 102:

```swift
switchSource: toolbarController.switchSourceItem.popUpButton.rx.selectedItemRepresentedObject(String.self).asSignal(),
```

With:

```swift
switchSource: toolbarController.switchSourceItem.rx.menuItemClick(String.self).asSignal(),
```

- [ ] **Step 2: Replace the runtimeEngineSections binding with two new bindings**

Remove the entire block (lines 151–176):

```swift
output.runtimeEngineSections.drive(
    toolbarController.switchSourceItem.popUpButton.rx.sectionItems(
        ...
    )
).disposed(by: rx.disposeBag)
```

Replace with:

```swift
// Bind menu content — rebuild menu from sections with selected engine marked
Driver.combineLatest(
    output.runtimeEngineSections,
    output.switchSourceState.map(\.selectedEngineIdentifier).distinctUntilChanged().map { AnyHashable($0) as AnyHashable? }
).drive(
    toolbarController.switchSourceItem.rx.sectionItems(
        sectionTitle: { $0.hostName },
        items: { $0.engines },
        itemTitle: { $0.source.description },
        itemImage: { engine in
            switch engine.source {
            case .local:
                return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
            case .remote(_, let identifier, _) where identifier == .macCatalyst:
                return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
            default:
                if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
                    return RuntimeEngineManager.shared.cachedIcon(for: engine) ?? .symbol(name: RuntimeViewerSymbols.appFill)
                } else {
                    let fallback = engine.hostInfo.metadata.isSimulator ? NSWorkspace.shared.box.deviceSymbolIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier) : NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
                    return RuntimeEngineManager.shared.cachedIcon(for: engine) ?? fallback
                }
            }
        },
        itemRepresentedObject: { AnyHashable($0.engineID) },
        configureMenuItem: { menuItem, _ in
            menuItem.image?.size = NSSize(width: 20, height: 20)
        }
    )
).disposed(by: rx.disposeBag)

// Bind toolbar item display — title and image from switchSourceState
output.switchSourceState.driveOnNext { [weak self] state in
    guard let self else { return }
    toolbarController.switchSourceItem.displayTitle = state.title
    toolbarController.switchSourceItem.displayImage = state.image
    toolbarController.switchSourceItem.displayImage?.size = NSSize(width: 20, height: 20)
}.disposed(by: rx.disposeBag)
```

- [ ] **Step 3: Build and verify**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer && swift package update --package-path RuntimeViewerPackages && xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: Build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainWindowController.swift
git commit -m "feat: wire MainWindowController to NSMenuToolbarItem with disconnection state display"
```
