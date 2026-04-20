# Switch Source: NSMenuToolbarItem Migration Design

## Problem

When the currently selected engine disconnects, `terminateRuntimeEngine` removes it from `runtimeEngineSections`, which triggers a full rebuild of the `NSPopUpButton` menu. Since the previously selected engine no longer exists in the menu, the selection falls back to the first available item (typically the local Mac engine), forcing an unwanted UI switch.

**Desired behavior:** Keep the current sidebar/content/inspector intact (read-only), and show a "disconnected" indicator on the toolbar — without force-switching to another engine.

## Solution

Replace the `NSPopUpButton`-based `SwitchSourceToolbarItem` with `NSMenuToolbarItem`, which decouples the displayed title/image from the menu contents.

## Design

### SwitchSourceToolbarItem

Subclass `NSMenuToolbarItem` instead of wrapping an `NSPopUpButton` in `NSToolbarItem`.

```swift
class SwitchSourceToolbarItem: NSMenuToolbarItem {
    init() {
        super.init(itemIdentifier: .Main.switchSource)
        showsIndicator = true
        menu = NSMenu()
    }
}
```

The toolbar item's `title` and `image` are set directly by bindings, independent of menu contents.

### SwitchSourceState

A new value type in `MainViewModel` that captures the toolbar item's display state:

```swift
struct SwitchSourceState: Equatable {
    let title: String
    let image: NSImage?
    let isDisconnected: Bool
    let selectedEngineIdentifier: String
}
```

### MainViewModel Changes

- New `@Observed private(set) var switchSourceState: SwitchSourceState` property.
- Combine `runtimeEngineManager.rx.runtimeEngineSections` with `selectedEngineIdentifier` to derive the state:
  - If the selected engine's `engineID` exists in the current sections → normal state (title = engine source description, image = engine icon, isDisconnected = false).
  - If not found → disconnected state (title = "cached name (Disconnected)", image = cached icon dimmed, isDisconnected = true).
- Cache the last selected engine's display name and image so they survive removal from sections.
- Remove `selectedEngineIdentifier` from `Output` (replaced by `switchSourceState`).
- The `input.switchSource` handler remains the same — only fires when user explicitly clicks a menu item.

### MainWindowController Binding Changes

Replace the single `output.runtimeEngineSections.drive(popUpButton.rx.sectionItems(...))` with two separate bindings:

1. **Menu content binding** — `output.runtimeEngineSections` drives the menu items via a new RxAppKit binder on `NSMenuToolbarItem`. The binder receives `selectedEngineIdentifier` to set `menuItem.state = .on` on the matching item.

2. **Toolbar display binding** — `output.switchSourceState` drives the toolbar item's `title` and `image` directly.

3. **Menu click signal** — A new RxAppKit `ControlEvent` on `NSMenuToolbarItem` emits the clicked item's `representedObject`, wired to `Input.switchSource`.

### RxAppKit: New NSMenuToolbarItem+Rx.swift

Add a new file with:

#### `sectionItems` Binder

```swift
func sectionItems<Section, Item>(
    sectionTitle: (Section) -> String,
    items: (Section) -> [Item],
    itemTitle: (Item) -> String,
    itemImage: ((Item) -> NSImage?)?,
    itemRepresentedObject: (Item) -> AnyHashable,
    selectedRepresentedObject: AnyHashable?,
    configureMenuItem: ((NSMenuItem, Item) -> Void)?
) -> Binder<[Section]>
```

Rebuilds `NSMenuToolbarItem.menu` from sections. Sets `state = .on` on the item matching `selectedRepresentedObject`.

#### `menuItemClick` ControlEvent

```swift
func menuItemClick<T: Hashable>(_ type: T.Type) -> ControlEvent<T?>
```

Each menu item's action targets the toolbar item (or a trampoline object). When a menu item is clicked, emits its `representedObject` typed as `T?`.

### Disconnection Data Flow

```
Engine disconnects
  → terminateRuntimeEngine (removes from sections, unchanged)
    → rebuildSections
      → runtimeEngineSections updated (engine gone)

MainViewModel observes runtimeEngineSections + selectedEngineIdentifier:
  → selectedEngineIdentifier NOT in sections
    → switchSourceState = SwitchSourceState(
        title: "cachedName (Disconnected)",
        image: cachedImage (dimmed),
        isDisconnected: true,
        selectedEngineIdentifier: currentID
      )

MainWindowController:
  → toolbar item title/image updated to show disconnected state
  → menu rebuilt without the disconnected engine
  → sidebar/content/inspector remain untouched (no route trigger)
```

### User Selects a New Engine

```
User clicks engine in menu
  → menuItemClick emits engineID
    → Input.switchSource
      → MainViewModel: lookup engine, trigger .main(engine), update selectedEngineIdentifier
        → switchSourceState recalculates to normal state
          → toolbar title/image updated
```

## Scope

### Changed Files

| File | Change |
|------|--------|
| `RxAppKit/.../NSMenuToolbarItem+Rx.swift` | **New** — sectionItems binder + menuItemClick event |
| `MainToolbarController.swift` | `SwitchSourceToolbarItem` → subclass `NSMenuToolbarItem` |
| `MainViewModel.swift` | Add `SwitchSourceState`, derive from sections + selectedID, cache display info |
| `MainWindowController.swift` | Update bindings: menu content, toolbar display, menu click signal |

### Unchanged

- `RuntimeEngineManager` — terminate/rebuild logic stays the same
- `MainCoordinator` — route handling stays the same
- `RuntimeEngineSection` — struct stays the same

## Platform

- `NSMenuToolbarItem` requires macOS 11+. RuntimeViewerPackages targets macOS 15+, so no compatibility concern.
- `NSMenuItem.sectionHeader` requires macOS 14+, same as existing code.
