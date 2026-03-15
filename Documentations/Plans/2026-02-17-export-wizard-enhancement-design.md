# Export Wizard Enhancement Design

## Goal

Enhance the export feature to support selective object export with separate ObjC/Swift format configuration, using a multi-step wizard with NSTabViewController.

## Current State

The existing export UI is a single `ExportingViewController` with 3 inline page views (configuration, progress, completion) managed by manual view swapping. It exports all RuntimeObjects in the current image with a single format choice.

## Requirements

1. **Selective export**: Users can choose which RuntimeObjects to export (default: all selected)
2. **ObjC/Swift separate configuration**: Each language type has its own format choice (single file / directory)
3. **Multi-step wizard**: Each step is a separate ViewController, hosted by NSTabViewController

## Wizard Steps

| Step | Name | Purpose |
|------|------|---------|
| 1 | Selection | List all RuntimeObjects in current image, grouped by ObjC/Swift, default all selected, user can toggle |
| 2 | Configuration | Separate format selection for ObjC and Swift (single file / directory structure) |
| 3 | Export | Directory picker → progress → completion summary |

## Architecture

```
MainCoordinator
└── prepareTransition(.exportInterfaces)
    └── ExportingCoordinator (new, manages wizard flow)
        └── ExportingTabViewController (NSTabViewController, .noTabsNoBorder)
            ├── Tab 0: ExportingSelectionViewController + ExportingSelectionViewModel
            ├── Tab 1: ExportingConfigurationViewController + ExportingConfigurationViewModel
            └── Tab 2: ExportingProgressViewController + ExportingProgressViewModel
```

### Shared State

```swift
final class ExportingState {
    let imagePath: String
    let imageName: String
    var allObjects: [RuntimeObject] = []
    var selectedObjCObjects: [RuntimeObject] = []
    var selectedSwiftObjects: [RuntimeObject] = []
    var objcFormat: ExportFormat = .singleFile
    var swiftFormat: ExportFormat = .singleFile
    var destinationURL: URL?
}
```

Created by ExportingCoordinator and passed to each sub-ViewModel.

### ExportingCoordinator

- Inherits from appropriate coordinator base
- Creates ExportingTabViewController and all sub-VCs
- Manages tab transitions (next/back)
- Handles dismiss routing via MainRoute

### ExportingTabViewController

- NSTabViewController subclass
- `tabStyle = .unspecified` (no visible tabs — navigation via Next/Back buttons)
- Hosts the 3 step VCs as tab items
- Provides `showStep(_:)` method for coordinator to drive transitions

## Step Details

### Step 1: Selection

**UI Layout:**
- Header: icon + "Export Interfaces" title
- Image name display
- Two grouped sections (ObjC / Swift), each with:
  - Group header with "Select All" checkbox
  - NSTableView or NSOutlineView with checkbox column listing RuntimeObjects
- Footer: summary text ("12 ObjC classes, 8 Swift types selected")
- Buttons: Cancel | Next →

**Behavior:**
- On load, fetch all RuntimeObjects for the image from RuntimeEngine
- Default: all objects selected
- "Select All" checkbox per group toggles entire group
- Next button disabled if nothing selected

### Step 2: Configuration

**UI Layout:**
- Header: "Export Format" title
- Selection summary from Step 1
- Two format selection areas:
  - **ObjC Export Format**: radio buttons (Single File .h / Directory Structure)
  - **Swift Export Format**: radio buttons (Single File .swiftinterface / Directory Structure)
- Each with brief description text
- Buttons: ← Back | Cancel | Export…

**Behavior:**
- Shows count of selected ObjC and Swift objects
- If no ObjC objects selected, ObjC section hidden/disabled (and vice versa for Swift)
- "Export…" triggers directory selection panel

### Step 3: Progress / Completion

**UI Layout (Progress):**
- Phase label ("Exporting interfaces...")
- Progress bar
- Current object label
- Cancel button

**UI Layout (Completion):**
- Checkmark icon + "Export Complete"
- Summary: succeeded count, failed count, duration, ObjC/Swift breakdown
- Buttons: Show in Finder | Done

**Behavior:**
- Reuses existing export logic from ExportingViewModel
- Two internal states (progress / completion) managed within this single VC
- Cancel during export cancels the async task

## Navigation Flow

```
Step 1 → validate(≥1 selected) → Step 2
Step 2 → Back → Step 1
Step 2 → Export… → directory picker → Step 3 (auto-start export)
Step 3 → Cancel → dismiss
Step 3 → Done → dismiss
Step 3 → Show in Finder → open Finder + stay
Any step → Cancel → dismiss
```

## Route Changes

- `MainRoute.exportInterfaces` remains unchanged
- `MainCoordinator.prepareTransition(.exportInterfaces)` creates `ExportingCoordinator` instead of directly creating VC+VM
- No new routes needed in MainRoute; internal wizard navigation handled by ExportingCoordinator

## Export API Integration

The existing `RuntimeEngine.exportInterfaces(in:options:reporter:)` exports all objects in an image. For selective export, use the per-object API:

```swift
// Export selected objects individually
for object in selectedObjects {
    let item = try await engine.exportInterface(for: object, options: options)
}
```

The writer needs to be called twice (once for ObjC items, once for Swift items) if formats differ.

## Files to Create/Modify

### New Files
- `Exporting/ExportingState.swift` — shared wizard state
- `Exporting/ExportingCoordinator.swift` — wizard coordinator
- `Exporting/ExportingTabViewController.swift` — NSTabViewController host
- `Exporting/ExportingSelectionViewController.swift` — Step 1 VC
- `Exporting/ExportingSelectionViewModel.swift` — Step 1 VM
- `Exporting/ExportingConfigurationViewController.swift` — Step 2 VC
- `Exporting/ExportingConfigurationViewModel.swift` — Step 2 VM
- `Exporting/ExportingProgressViewController.swift` — Step 3 VC
- `Exporting/ExportingProgressViewModel.swift` — Step 3 VM

### Modified Files
- `Main/MainCoordinator.swift` — update `.exportInterfaces` case to use ExportingCoordinator
- Delete or repurpose old `ExportingViewController.swift` and `ExportingViewModel.swift`
