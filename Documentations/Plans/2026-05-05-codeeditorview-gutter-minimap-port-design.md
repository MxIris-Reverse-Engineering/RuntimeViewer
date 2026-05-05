# CodeEditorView Gutter & Minimap Port — Design

## Overview

Port the **Gutter** (line numbers + current-line highlight) and **Minimap** (scaled overview + draggable viewport indicator) features from [mchakravarty/CodeEditorView](https://github.com/mchakravarty/CodeEditorView) into RuntimeViewer's read-only `ContentTextViewController`. Cross-platform (macOS AppKit + iOS UIKit). The components are bundled into a reusable container `CodePreviewContainerView` that lives in `RuntimeViewerUI`, and the existing `ContentTextViewController` on each platform embeds it in place of the current `NSScrollView` + `NSTextView` pair.

The port is **trimmed**, not faithful: drop CodeEditorView's `MessageViews` / `Theme` protocol / `CodeStorage` / `LineMap<LineInfo>` / `isMinimapGutter` abstractions because RuntimeViewer is a read-only interface viewer with no warnings, breakpoints, code completion, or editing.

Gutter and minimap visibility are user-configurable via two new toggles in Settings (`Show Line Numbers`, `Show Minimap`). Colors derive from the existing `ThemeProfile` (`backgroundColor`, `selectionBackgroundColor`, `color(for: .comment)`) — no protocol changes.

## Goals

- **G1** Display line numbers in a floating gutter on the left side of the main text view, synced to vertical scroll.
- **G2** Highlight the current/selected line(s) in the gutter.
- **G3** Single-click on a gutter line number selects the entire corresponding line.
- **G4** Display a minimap on the right showing scaled rendering of the document content with rendering-attribute colors.
- **G5** Show a viewport indicator box on the minimap reflecting the main view's visible region.
- **G6** Click on the minimap teleports the main view to center on the clicked position.
- **G7** Drag the viewport indicator scrolls the main view proportionally.
- **G8** Both Gutter and Minimap are toggleable via Settings (default both on).
- **G9** Gutter and Minimap colors derive from the existing `ThemeProfile` and adapt to Light/Dark.
- **G10** Cross-platform: macOS (AppKit, primary) and iOS (UIKit) end up with the same visible behavior.

## Non-Goals

- Message indicators (warnings/errors) on gutter — RuntimeViewer has no messages.
- Code folding, breakpoints, per-line metadata.
- Embedded mini-gutter inside minimap (CodeEditorView's `isMinimapGutter` mode).
- Editing-related concerns (multi-cursor, undo, completion).
- SwiftUI wrapper of the container (per project rule: no SwiftUI outside Settings).
- iOS-side Settings binding — `RuntimeViewerSettings` is currently AppKit-only; iOS uses default values.
- Long-document performance optimization (>5k-line interfaces). Tracked as a follow-up risk (R1) with a stretch fallback.

## Architecture

```
┌─ CodePreviewContainerView (NSUIView) ─────────────────┐
│                                                       │
│  ┌─ scrollView ────────────────────────────┐  ┌─ minimap ─┐
│  │ ┌─ gutter ─┐ ┌─ main text view ─────┐   │  │   text    │
│  │ │ 1        │ │ /// header            │  │  │  ░ ░ ░    │
│  │ │ 2        │ │ class Foo {           │  │  │  ░░░  ░   │
│  │ │ 3 ◀ cur  │ │     var bar: Int      │  │  │  ▓▓▓▓  ◀ viewport box
│  │ │ 4        │ │ }                     │  │  │   ░ ░     │
│  │ └──────────┘ └──────────────────────┘   │  │           │
│  └─────────────────────────────────────────┘  └───────────┘
└───────────────────────────────────────────────────────────┘
```

### Platform differences

- **AppKit**: gutter uses `NSScrollView.addFloatingSubview(_, for: .vertical)`; minimap is a separate `NSScrollView` with hidden scrollers, driven manually. Mirrors CodeEditorView's approach.
- **UIKit**: `UIScrollView` has no floating-subview API. Gutter and minimap are siblings of the scroll view inside the container; gutter syncs via `scrollViewDidScroll` (or KVO on `contentOffset` for smoother sync).

The container exposes the API surface of "an enhanced text view" — `attributedString`, `theme`, `showsLineNumbers`, `showsMinimap`, `onLinkClicked`, plus access to the underlying `textView`. Internal three-piece composition stays internal.

## Component Breakdown

All new files live in `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/`.

### `NSUITypeAliases.swift` (~30 LOC)

Supplements the `NSUI*` typealiases provided by `UIFoundation`. Defines:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public typealias NSUITextView = NSTextView
public typealias NSUIScrollView = NSScrollView
#elseif canImport(UIKit)
public typealias NSUITextView = UITextView
public typealias NSUIScrollView = UIScrollView
#endif
```

Kept narrow-scoped (file-private to this folder by convention) rather than upstreamed to UIFoundation, because `NSTextView` and `UITextView` have wildly divergent APIs and a global typealias is easy to misuse outside this carefully-bounded code.

`NSTextLayoutManager`, `NSTextLineFragment`, `NSTextLayoutFragment`, `NSTextRange`, `NSTextLocation` are already cross-platform (TextKit 2 ships on both), no aliases needed.

### `LineMap.swift` (~80 LOC)

Minimal "char position ↔ line number" lookup. Stores `[NSRange]` of line ranges; rebuilt fully whenever `attributedString` is replaced (RuntimeViewer is read-only and replaces wholesale, no need for incremental updates).

```swift
struct LineMap {
    private(set) var lines: [NSRange]  // sorted, non-overlapping

    init(string: String)
    func lineNumber(for charIndex: Int) -> Int?           // 1-based
    func range(forLine lineNumber: Int) -> NSRange?       // 1-based input
    func lines(intersecting range: NSRange) -> ClosedRange<Int>?
}
```

`init(string:)` does a single linear scan for `\n`. `lineNumber(for:)` uses binary search.

Distinct from CodeEditorView's `LineMap<LineInfo>`: no generic per-line metadata, no incremental `updateAfterEditing`, no support for arbitrary edits.

### `GutterView.swift` (~250 LOC)

Cross-platform gutter view inheriting `NSUIView`. Renders line numbers and current-line highlight; handles single-click on line numbers to select the entire line.

API surface:
```swift
final class GutterView: NSUIView {
    weak var textView: NSUITextView?
    weak var scrollView: NSUIScrollView?
    var lineMap: LineMap = .init(string: "")
    var theme: ThemeProfile?
    var highlightedLines: ClosedRange<Int>? // current line(s)
    var verticalOffset: CGFloat = 0          // UIKit only; ignored on AppKit (floating)

    func invalidate()                        // forces redraw
}
```

Drawing:
- Background: `theme.gutterBackgroundColor` (derived; see `ThemeColorDerivation.swift`).
- Line number text: `theme.gutterLineNumberColor`, monospaced font, right-aligned in gutter.
- Current line highlight: `theme.gutterCurrentLineColor` (translucent), full gutter width, behind line number.
- Width: `7 * font.maximumHorizontalAdvancement` + padding (per CodeEditorView convention; supports up to 7-digit line counts).

Click:
- AppKit: `mouseDown(with:)` → hit-test → set `textView.selectedRange = lineRange` → invalidate.
- UIKit: `UITapGestureRecognizer` → same.

Trimmed from CodeEditorView original:
- No `MessageViews` lookup closure.
- No `isMinimapGutter` mode.
- Theme is a direct property, not closure-injected.
- Uses our minimal `LineMap`, not `LineMap<LineInfo>`.

### `MinimapView.swift` (~340 LOC, supersedes existing)

Replaces the current `RuntimeViewerUI/AppKit/MinimapView.swift`. Cross-platform via `NSUITextView`. Preserves the existing `MinimapLineFragment`, `MinimapLayoutFragment`, `MinimapTextLayoutManagerDelegate`, and `minimapRatio = 8` constant; the `NSAttributedString.Key.hideInvisibles` extension migrates as well.

Adds:
- Cross-platform initializer using TextKit 2 (`usingTextLayoutManager: true` on both platforms).
- Hookup of the layout-manager delegate that swaps in `MinimapLayoutFragment`.
- Connects to the same content storage as the main text view (so they share text without double-storage).

### `MinimapViewportIndicator.swift` (~120 LOC)

Independent `NSUIView` overlaid on the minimap. Renders a translucent rectangle representing the visible region of the main text view.

```swift
final class MinimapViewportIndicator: NSUIView {
    var fillColor: NSUIColor = .clear
    var dragFillColor: NSUIColor = .clear
    var onDrag: ((CGFloat) -> Void)?  // delta-y in indicator coordinates
    var onClick: ((CGFloat) -> Void)? // tap location-y in minimap coordinates (when click outside indicator)
}
```

- AppKit: `mouseDown` / `mouseDragged` / `mouseEntered` / `mouseExited` (tracking area for hover state).
- UIKit: `UIPanGestureRecognizer` for drag; no hover state.
- Visual states: idle (`fillColor`, alpha 0.18), hover (alpha 0.30, AppKit only), drag (alpha 0.30).

### `CodePreviewContainerView.swift` (~300 LOC)

The orchestration view. Public API:

```swift
public final class CodePreviewContainerView: NSUIView {
    public let textView: NSUITextView
    public var attributedString: NSAttributedString? { get set }
    public var theme: ThemeProfile? { get set }
    public var showsLineNumbers: Bool { get set }   // default true
    public var showsMinimap: Bool { get set }       // default true
    public var onLinkClicked: ((Any, Int) -> Void)? // forwarded from textView delegate

    public init(textViewType: NSUITextView.Type = NSTextView.self)
}
```

Holds: `mainScrollView`, `gutterView`, `minimapScrollView` (containing a `MinimapView`), `viewportIndicator`. Wires:
- Shared `NSTextContentStorage` between main and minimap text views, so the minimap mirrors content for free without double-storage.
- Custom `NSTextLayoutManagerDelegate` (`MinimapTextLayoutManagerDelegate`) on the minimap's layout manager to inject `MinimapLayoutFragment`.

Internal methods:
- `tile()` — lays out gutter / scroll view / minimap; toggles visibility per `showsLineNumbers` / `showsMinimap`; called on `layoutSubviews` / `layout` and when toggle properties change.
- `adjustScrollPositionOfMinimap()` — sets minimap scroll offset and viewport-indicator frame from the main scroll view's offset.
- Selection / scroll callbacks → invalidate gutter highlight, update viewport indicator.

`textViewType` parameter lets `ContentTextViewController` pass `ContentTextView.self` (its current subclass override of `clicked(onLink:at:)` and `acceptableDragTypes`).

### `ThemeColorDerivation.swift` (~60 LOC)

`extension ThemeProfile` adding computed properties:

```swift
extension ThemeProfile {
    var gutterBackgroundColor: NSUIColor { /* dynamic light/dark; from backgroundColor */ }
    var gutterLineNumberColor: NSUIColor { color(for: .comment) }
    var gutterCurrentLineColor: NSUIColor { /* selectionBackgroundColor.withAlphaComponent(0.15) */ }
    var minimapBackgroundColor: NSUIColor { /* same derivation as gutterBackgroundColor */ }
    var viewportIndicatorColor: NSUIColor { /* selectionBackgroundColor.withAlphaComponent(0.18) */ }
    var viewportIndicatorActiveColor: NSUIColor { /* alpha 0.30 */ }
}
```

The "background tint shift" uses `NSUIColor(light: .. , dark: ..)` — separate light and dark expressions instead of runtime luminance detection. The current `XcodePresentationTheme.backgroundColor` is itself `NSUIColor(light:dark:)`, so the derivations decompose into matching light/dark variants.

### Modifications

| File | Change |
|---|---|
| `RuntimeViewerUI/AppKit/MinimapView.swift` | **Delete** (moved to `CodePreview/MinimapView.swift`). Verified no external references. |
| `RuntimeViewerUI/AppKit/NSTextLayoutManager+.swift` | Make cross-platform (move file out of `AppKit/` into a shared location, narrow `#if` to specific differences). |
| `RuntimeViewerUI/AppKit/NSTextContentStorage+.swift` | Same — make cross-platform. |
| `RuntimeViewerSettings/Settings+Types.swift` | Add `Settings.CodePreview` struct with `showsLineNumbers: Bool = true`, `showsMinimap: Bool = true`. |
| `RuntimeViewerSettings/Settings.swift` | Add `@Default(CodePreview.default) public var codePreview` and load/save plumbing. |
| `RuntimeViewerSettingsUI/Components/CodePreviewSettingsView.swift` (new) | SwiftUI two-toggle view, follows `GeneralSettingsView` style. |
| `RuntimeViewerSettingsUI/SettingsRootView.swift` | Register new tab. |
| `RuntimeViewerSettingsUI/SettingsIcon.swift` | Add tab icon `text.alignleft`. |
| `RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift` | Replace `(scrollView, textView)` with `codePreviewContainer`. Migrate textView config to `codePreviewContainer.textView`. Subscribe `Settings.codePreview` → drive `showsLineNumbers` / `showsMinimap`. |
| `RuntimeViewerUsingUIKit/Content/ContentTextViewController.swift` | Mirror change. No Settings subscription (no Settings on iOS). |

`ContentTextViewModel` is **unchanged** — settings binding lives in the ViewController as a pure UI concern.

`ThemeProfile` protocol is **unchanged** — derived colors via extension only.

## Scroll Synchronization

### Position mapping (main ↔ minimap)

```
scrollFactor = (codeHeight - visibleHeight) /
               max(1, minimapHeight - minimapVisibleHeight)

minimapOffsetY = mainOffsetY / scrollFactor    // bounded to [0, minimapHeight - minimapVisibleHeight]
```

When `codeHeight <= visibleHeight`, `scrollFactor` defaults to `1` (no scrolling needed).

### Viewport indicator geometry

```
indicatorY = (mainOffsetY / codeHeight) * minimapDocumentHeight - minimapContentOffsetY
indicatorH = (visibleHeight / codeHeight) * minimapDocumentHeight
```

`indicatorY` is the on-screen y; the minimap's own scroll offset is subtracted because the indicator is rendered as a floating sibling of the minimap's text content.

### AppKit path

- `mainScrollView.contentView.postsBoundsChangedNotifications = true`.
- Listen to `NSView.boundsDidChangeNotification` on `mainScrollView.contentView`.
- Handler calls `adjustScrollPositionOfMinimap()`.
- Gutter is added via `mainScrollView.addFloatingSubview(gutterView, for: .vertical)`. Its x is auto-managed; the gutter only needs to redraw on scroll (vertical positioning happens via TextKit's layout manager redrawing).
- Viewport indicator is `addSubview` on the minimap's documentView (it's on top of minimap text but the indicator's frame is updated explicitly, not via a scroll-content relationship).

### UIKit path

- `mainScrollView.delegate?.scrollViewDidScroll` (or `addObserver(self, forKeyPath: "contentOffset")` for earlier sync timing).
- Gutter: `transform = CGAffineTransform(translationX: 0, y: -mainScrollView.contentOffset.y + initialY)` so the gutter visually stays put while content scrolls beneath it. Chosen over a `verticalOffset` parameter applied in `draw(_:)` because it avoids redrawing the gutter on every scroll tick.
- Minimap and viewport indicator are siblings of `mainScrollView` inside `CodePreviewContainerView`, not embedded within the scroll view.

### Edit/replace timing

When `attributedString` is replaced:
1. The main and minimap text views share a single `NSTextContentStorage`; the container sets the attributed string once on the shared storage's underlying `NSTextStorage` and both views update.
2. Rebuild `LineMap` from the new string.
3. Defer `tile()` and `adjustScrollPositionOfMinimap()` to the next runloop tick (`Task { @MainActor in ... }`) so TextKit 2 has finished laying out and `codeHeight` is correct.

If `tile()` runs synchronously after `setAttributedString`, `codeHeight` may still reflect the old document, and the viewport indicator will be sized incorrectly.

### Drag feedback loop avoidance

While the user is dragging the viewport indicator, the indicator's own pan handler updates `mainScrollView.contentOffset`, which triggers `boundsDidChange` → `adjustScrollPositionOfMinimap()` → moves the minimap → moves the indicator. This loop is fine in isolation but causes a tiny jitter and wasted re-layouts.

Mitigation: an `isDriverScroll` flag set during drag; the bounds-change handler skips minimap adjustment when set. Indicator's pan handler updates main offset and indicator frame directly.

## User Interactions

### Gutter

- **Click line number**: `mouseDown` / tap → hit-test the y-coordinate to a line via `LineMap` → set `textView.selectedRange` to that line's full range → invalidate gutter.
- **Current-line highlight**: subscribe to `textViewDidChangeSelection` → compute `lineMap.lines(intersecting: selection)` → store as `gutterView.highlightedLines` → invalidate.
- **Hit isolation**: `CodePreviewContainerView.hitTest` keeps gutter clicks from reaching the text view (so dragging on gutter selects line, not text).

### Minimap

- **Click outside indicator**: convert click y to document y (`docY = (clickY + minimap.contentOffsetY) * minimapRatio`) and set `mainScrollView.contentOffset.y = docY - visibleHeight / 2`, clamped.
- **Drag indicator**: pan / `mouseDragged` adjusts `mainScrollView.contentOffset.y += Δscreen * scrollFactor`, clamped.
- **Drag minimap text region** (non-indicator): not implemented this iteration. Click-only.

## Settings Integration

### `Settings.CodePreview`

```swift
@Codable
@MemberInit
public struct CodePreview {
    @Default(true) public var showsLineNumbers: Bool
    @Default(true) public var showsMinimap: Bool
    public static let `default` = Self()
}
```

Wired into `Settings` next to the existing `general`, `notifications`, `transformer`, `mcp`, `indexing`, `update` properties, with `didSet { scheduleAutoSave() }` and `load()` plumbing.

### Settings UI

`CodePreviewSettingsView.swift`:

```swift
struct CodePreviewSettingsView: View {
    @AppSettings(\.codePreview) var settings

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Show Line Numbers", isOn: $settings.showsLineNumbers)
                Toggle("Show Minimap", isOn: $settings.showsMinimap)
            }
        }
    }
}
```

Tab icon: `text.alignleft`.

### Subscription in ContentTextViewController (AppKit)

In `setupBindings(for:)`:

```swift
let codePreviewObservable = Observable<Settings.CodePreview>.create { observer in
    let settings = Settings.shared
    observer.onNext(settings.codePreview)
    func observe() {
        withObservationTracking { _ = settings.codePreview }
        onChange: { DispatchQueue.main.async { observer.onNext(settings.codePreview); observe() } }
    }
    observe()
    return Disposables.create()
}

codePreviewObservable.observeOnMainScheduler()
    .subscribeOnNext { [weak self] config in
        guard let self else { return }
        codePreviewContainer.showsLineNumbers = config.showsLineNumbers
        codePreviewContainer.showsMinimap = config.showsMinimap
    }
    .disposed(by: rx.disposeBag)
```

(Mirrors the pattern already used by `ContentTextViewModel` for `transformerObservable`.)

## Test Plan

### Unit tests

New target / additions to existing test target:

- **`LineMapTests`**: input strings covering single-line, multi-line LF, CRLF, trailing newline, empty string, single-character lines. Assert `lineNumber(for:)`, `range(forLine:)`, `lines(intersecting:)`.
- **`ThemeColorDerivationTests`**: with `XcodePresentationTheme()`, derived colors are non-clear and visually distinct from `backgroundColor`.

### Manual tests (run during implementation)

- Open short (~50-line), medium (~500-line), long (~5000-line) interfaces. Verify gutter line numbers correct, minimap renders, viewport indicator sized appropriately.
- Toggle `Show Line Numbers` and `Show Minimap` from Settings → container relayouts immediately, no leftover ghost frames.
- Vertical scroll main view → minimap viewport indicator follows.
- Drag viewport indicator → main view scrolls.
- Click minimap (outside indicator) → main view jumps with clicked line near vertical center.
- Click gutter line number → that line is selected in the text view, gutter highlights it.
- Switch Settings → Appearance Light/Dark → gutter and minimap colors update.
- Cmd-click on link → still navigates (existing jump-to-definition unbroken).
- Find bar (Cmd+F) → still works on the container's text view.
- Right-click context menu → existing menu items (cut/copy/paste, jump-to-definition) still appear.

### Out of test scope this iteration

- Snapshot tests (no snapshot framework in project; not introducing one).
- Automated performance benchmarks.

## Risks

| ID | Risk | Mitigation |
|---|---|---|
| **R1** | Long interfaces (>5k lines) cause minimap layout (`MinimapLayoutFragment.updateTextLineFragments`) to take >300ms and stall UI. | Measure during implementation. If observed, add stretch fallback: auto-hide minimap when `attributedString.length` exceeds a threshold (e.g., 100k chars). Not mandatory for first cut. |
| **R2** | TextKit 2 layout incomplete when `tile()` runs after `setAttributedString` → wrong `codeHeight` → wrong viewport box. | Defer `tile()` to next runloop via `Task { @MainActor in ... }`. Documented in §"Scroll Synchronization → Edit/replace timing". |
| **R3** | AppKit's `addFloatingSubview` auto-manages child frame; conflicts with SnapKit constraints inside the gutter. | Gutter's internal layout uses manual frame setting in `layout()` / `viewDidMoveToSuperview`, not SnapKit. |
| **R4** | UIKit's `scrollViewDidScroll` fires after the visual scroll, causing a 1-frame jitter when transforming gutter / minimap. | KVO on `contentOffset` fires earlier (`willChange` semantics). Fall back to `CADisplayLink` if KVO has Swift 6 strict-concurrency warnings. |
| **R5** | Deletion of existing `RuntimeViewerUI/AppKit/MinimapView.swift` breaks an unforeseen reference. | `grep` confirms no current external use; `NSAttributedString.Key.hideInvisibles` extension migrates with the file. |
| **R6** | `NSUIColor(light:dark:)` derivation requires separate light/dark expressions; runtime luminance detection on `backgroundColor` is fragile. | Decompose `XcodePresentationTheme.backgroundColor` (already a `light:dark:` color) into its light/dark variants, derive each side at theme-property-access time. No runtime luminance branching. |

## File Layout Summary

```
RuntimeViewerPackages/
  Sources/
    RuntimeViewerUI/
      CodePreview/                              ← NEW directory
        NSUITypeAliases.swift                    NEW
        LineMap.swift                            NEW
        GutterView.swift                         NEW
        MinimapView.swift                        NEW (supersedes AppKit/MinimapView.swift)
        MinimapViewportIndicator.swift           NEW
        CodePreviewContainerView.swift           NEW
        ThemeColorDerivation.swift               NEW
      AppKit/
        MinimapView.swift                        DELETED
        NSTextLayoutManager+.swift               MOVE+adjust (cross-platform)
        NSTextContentStorage+.swift              MOVE+adjust (cross-platform)
    RuntimeViewerSettings/
      Settings+Types.swift                       MODIFY
      Settings.swift                             MODIFY
    RuntimeViewerSettingsUI/
      SettingsRootView.swift                     MODIFY
      SettingsIcon.swift                         MODIFY
      Components/
        CodePreviewSettingsView.swift            NEW

RuntimeViewerUsingAppKit/
  RuntimeViewerUsingAppKit/Content/
    ContentTextViewController.swift              MODIFY

RuntimeViewerUsingUIKit/
  RuntimeViewerUsingUIKit/Content/
    ContentTextViewController.swift              MODIFY
```

Approximate sizes: ~1180 LOC new, ~400 LOC modified.

## Dependencies

- `Rearrange` — already a dependency of `RuntimeViewerUI` (no new package introduction).
- `UIFoundation` (NSUI typealiases) — already a dependency.
- No CodeEditorView dependency: source ported directly with simplifications.

## Decision Log (from brainstorming)

| # | Question | Choice |
|---|---|---|
| 1 | Port scope | **B**: trimmed (no MessageViews / Theme protocol / CodeStorage / LineMap<LineInfo>) |
| 2 | Platforms | **B**: macOS (AppKit) + iOS (UIKit) |
| 3 | Behavior | **b+d+g**: Settings toggles + minimap drag + gutter line click with current-line highlight |
| 4 | Code organization | **A**: cross-platform container in `RuntimeViewerUI`, NSUI prefix (UIFoundation), local supplemental aliases for `NSUITextView`/`NSUIScrollView` |
| 5 | Theme color strategy | **B**: derive via `ThemeProfile` extension, no protocol changes |
