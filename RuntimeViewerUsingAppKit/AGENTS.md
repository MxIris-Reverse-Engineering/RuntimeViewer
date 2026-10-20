# AGENTS.md — the macOS app's UI layer

Rules for the app's UI code — ViewModels, ViewControllers, cells and cell ViewModels, coordinators and
routes, AppKit views — and for `AppDelegate` and the lifecycle controllers. The UI code is the app
target's folder below this directory, `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`, plus the
ViewModels, cell ViewModels and routes in `RuntimeViewerPackages/Sources/RuntimeViewerApplication/` and
the views in `RuntimeViewerPackages/Sources/RuntimeViewerUI/` (`RuntimeViewerPackages/Sources/AGENTS.md`
points here). The other targets in this directory — the Catalyst shells and plugin, the XPC services, the
command-line tool target — follow these rules only where they have UI code, and the SourceEditor bridge
and the `Content/SourceEditor…` files are governed by `Stubs/AGENTS.md`, which must be read before
touching them. The repository-wide rules — naming, access control, singletons, RxSwift subscription
style, closure capture — are in the root `AGENTS.md`.

This file sits here rather than in the target folder because every target folder below this directory
is an Xcode synchronized folder: a file put in one becomes a resource of its target.

## MVVM-C

**Every ViewController has a ViewModel.** Business logic — service calls, state management, pasteboard
operations — never goes in the ViewController, which only lays out its views, turns control events into
the ViewModel's `Input`, and binds the `Output` to its views in `setupBindings(for:)`. The coordinator
creates both (see *Coordinators and Routes*).

## ViewModels

- **Base class**: every ViewModel inherits `ViewModel<Route>`, which provides `documentState`, `router`,
  `appDefaults`, `errorRelay` and `_commonLoading`. Other dependencies come through `@Dependency(\.xxx)`.
- **State is `@RxObserved private(set) var`, never `BehaviorRelay`**, exposed as `$property.asDriver()` /
  `$property.asSignal()` and mutated by plain assignment (`currentPage = .progress`). **Read the property
  for its current value; touch `$property` only to subscribe or bind.** `@RxObserved` creates its
  `BehaviorRelay` on the first `$property` access (proposal *`@RxObserved` 惰性创建 relay*), so a
  `$property.value` in a bulk path — a filter pass, type-select, an export loop — materializes one relay
  plus an `NSRecursiveLock` per row and silently undoes the saving. `SidebarFilterRelayMaterializationTests`
  guards the sidebar paths; keep new bulk paths on `wrappedValue`.
- **`transform(_ input: Input) -> Output`**: `Input` is a `@MemberwiseInit(.public) struct` of `Signal`s;
  `Output` carries state as `Driver`s and one-shot events as `Signal`s fed by a
  `private let …Relay = PublishRelay<…>()`. `ContentTextViewModel` is the reference.
- **Errors**: `errorRelay.accept(error)` — from an async context, `await MainActor.run { self.errorRelay.accept(error) }`.
  The ViewController base class presents the alert.

**Async content — one state enum, never `isLoading` + `content` side by side.** When a pane's content
comes from an `async` engine call, model loading and content as a *single* `@RxObserved` value:

```swift
public enum HierarchyState { case loading, loaded(String) }

$runtimeObject
    .flatMapLatest { runtimeObject in
        Observable<HierarchyState>.async { .loaded(try await ...) }
            .withLoadingPlaceholder(
                .loading,
                appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
            )
    }
    .observeOnMainScheduler()
    .bind(to: $hierarchyState)
```

Two independent drivers let the view observe "not loading" together with the *previous* object's
content — a visible flash; one enum makes that state unrepresentable. `flatMapLatest` also drops the
in-flight call when the selection moves on; a bare `Task { }` does not, so a slow result can land on top
of a newer one.

- **Never emit the loading state with a bare `startWith`.** Use `withLoadingPlaceholder(_:appearsAfter:staysAtLeast:)`
  (RuntimeViewerArchitectures) with the shared `LoadingPlaceholderTiming` values, so the placeholder does
  not become the flicker it was meant to hide: work faster than `appearsAfter` shows no placeholder at
  all, and a placeholder that does appear stays up for `staysAtLeast` instead of blinking for a frame.
  Engine calls that hit a warm cache return in single-digit milliseconds, so this is the common case.
- Build the pipeline in `init` and return `$state.asDriver()` from `transform`, the way
  `ContentTextViewModel` does. Values that build AppKit objects (cell ViewModels, `NSImage`,
  `NSAttributedString`) are mapped **after** `observeOnMainScheduler()`; only plain model data crosses
  back from the background.

**Reusable panes: keep the ViewModel, swap the object.** A pane that shows a series of objects (Inspector
tabs, Content text) must not build a fresh ViewModel and call `setupBindings(for:)` per object:
`setupBindings` resets `rx.disposeBag`, which tears down `tableView.rx.items` and installs a *new*
RxAppKit adapter starting from an empty item list — the table blanks on the spot. Give the ViewModel an
`update(for:)` that returns early when `self.runtimeObject == runtimeObject` and otherwise assigns the new
object to the `@RxObserved` property the pipeline is already keyed on, and have the coordinator hold the
ViewModel. The identity guard matters: re-entering the same object (a `.back` route from a tab close or a
history cursor move) must not refetch, or the loading placeholder flashes over content that is already
correct.

**`==` on `RuntimeObject` is identity only** — `(imagePath, name, kind)`, the same triple as
`RuntimeObjectKey`; `displayName`, `children` and `properties` do not take part (Evolution 0021). That is
the right guard for a pane that *fetches* by the object, and the wrong one for a pane that *renders the
object's own fields*: the Inspector's Specialization tab lists `runtimeObject.children`, so it guards with
`hasSameContent(as:)`, or a type that has grown a specialization never shows it. Ask which one a new pane
is before copying the guard above. The same applies to anything that stores the form of a type it was
last given — the navigation timeline and the active tab replace an entry whose content differs even when
`==` holds. And never decide *which* type an object is from its `displayName`: one type prints under more
than one name (a nested protocol is listed by its short name in the sidebar and by its qualified name
after a jump).

## ViewControllers

**Base classes**:

- **`BaseViewController<VM>`** — the default. Built on UIFoundation's `LayerBackedViewController<LayerBackedView>`
  (AppKitPlus's `NSLayerBackedViewController` underneath, because the `AppKitPlus` trait is on), it carries
  the ViewModel plumbing plus `containerView`, the loading indicator (`CommonLoadingView`) and skeleton
  support. Two views, two jobs: the superclass's `contentView` is the root view itself, a UIFoundation
  `LayerBackedView`; `containerView` is the plain view inside it that applies `contentInsets` (and the
  safe area when `containerViewUsingSafeArea` is on) and stays under the loading indicator, so **pane
  content goes in `containerView`** — content added straight to `contentView` / `view` gets neither.
  `CommonLoadingView` is the system spinner (`NSProgressIndicator`) over frosted glass before macOS 26
  and over nothing from macOS 26 on; it covers the whole view and centres the spinner in the safe area. A
  pane that should be covered while it loads sets `commonLoadingView.backgroundColor`, which replaces the
  glass — the two content panes set the editor's background, an opaque plate over the minimap, the gutter
  and the strip under the toolbar. `delayedLoading` drives `isRunning` directly and is the only thing that
  changes it, so a pane rebound to a new ViewModel keeps its spinner until that ViewModel reports; do not
  seed it with a default. AppKitPlus's navigation stack takes plain `NSViewController`s, so nothing has
  to inherit a navigation-specific base. Background: `Documentations/Evolutions/0023-content-loading-overlay.md`,
  `Documentations/Evolutions/0024-layer-backed-view-controller-adoption.md`.
- **`BaseEffectViewController<VM>`** — when a visual effect background is needed (inherits
  `BaseViewController`). Before macOS 26 that background is an `NSVisualEffectView`; from macOS 26 it is
  a plain `NSView`, because the split view wraps the item in an `NSGlassEffectView` that no colour or
  material matches, so the page stays transparent and sits on that glass directly. **Do not give pages a
  resident background of their own**: the opaque backdrop the sidebar's push / pop needs is inserted
  under both sliding pages for the transition's duration by `NavigationTransitionBackdropController` (the
  sidebar navigation controller's delegate) — UIFoundation's `GlassEffectReplicaView` on macOS 27+, a glass
  that copies the enclosing glass and shares its backdrop group, and `windowBackgroundColor` on macOS 26.
  See `Documentations/ResolvedIssues/2026-09-18-sidebar-transition-backdrop-glass-replica.md`.

**UI events — prefer RxAppKit / RxCocoa `rx.*` accessors** over hand-rolled `PublishRelay` + `@objc`
action plumbing, wired straight into `Input`: `cancelButton.rx.click.asSignal()`,
`searchField.rx.stringValue.asSignal(onErrorJustReturn: "")`. The ones to know:

- `NSButton`: `rx.click`, `rx.state`, `rx.title`, `rx.isEnabled`
- `NSSearchField` / `NSTextField`: `rx.stringValue`, `rx.text`
- `NSTableView`: `rx.itemClicked()`, `rx.itemSelected()`, `rx.modelSelected()`, `rx.items`, `rx.setDelegate(_:)`
- `NSOutlineView`: `rx.modelDoubleClicked()`, `rx.modelSelected()`, `rx.nodes`, `rx.reorderableNodes`
- `NSView`: `rx.isHidden` and friends

**Avoid** `private let xxxRelay = PublishRelay<Void>()` + `@objc func xxxClicked()` +
`xxxButton.target = self; xxxButton.action = #selector(...)` for a single, statically known control —
use `xxxButton.rx.click.asSignal()`. `PublishRelay<T>` is reserved for events that **cannot** be expressed
as a control accessor: clicks aggregated from dynamically rebuilt child views (per-row buttons in a form —
`SpecializationViewController.requestTypePickerClickedRelay`), and one-shot events the ViewModel emits
through `Output`.

**`setupBindings(for:)`** calls `super.setupBindings(for: viewModel)`, builds the `Input`, calls
`viewModel.transform(input)`, and drives each `Output` into the views — `.drive(…)` / `.bind(to:)` for
plain bindings, `.driveOnNext { [weak self] … }` for logic — disposing into `rx.disposeBag`.

**Structure**: organize a ViewController with `// MARK: -` groups — Relays, its UI sections
(Configuration Page, …), Lifecycle, Actions, Page Management, Bindings. A custom view that one
ViewController needs is a private nested type with a namespace:
`extension MyViewController { private class HeaderView: NSView { ... } }`.

## Views

**Always check for project wrapper types first** (RuntimeViewerUI / UIFoundation / AppKitPlus), NOT raw
AppKit classes. When a wrapper cannot satisfy a specific need (e.g. `PushButton` has a fixed `.push`
bezelStyle), fall back to the raw AppKit class (`NSButton()` for `.accessoryBarAction`).

| Use | Instead of |
|-----|-----------|
| `Label()` / `Label("text")` | `NSTextField(labelWithString:)` |
| `PushButton()` | `NSButton()` |
| `ImageView()` | `NSImageView()` |
| `VStackView(alignment:spacing:) { ... }` | `NSStackView(orientation: .vertical)` |
| `HStackView(spacing:) { ... }` | `NSStackView(orientation: .horizontal)` |
| `ScrollView()` | `NSScrollView()` |
| `NSPopUpPathControl()` (AppKitPlus) | `NSPathControl()` for an Xcode-style path of menus (`Find ▸ Text ▸ Containing`) |
| `NSFilterSearchField()` (AppKitPlus) | `NSSearchField()` above a list it filters — the field of a page's filter bar, a picker's filter field |
| `NSFindPatternSearchField()` (AppKitPlus) | `NSSearchField()` for a query that takes find patterns (Digits, Any Word Characters…) among its text — the Find page's query field. Read `findPatternComponents`, never `stringValue`, which holds U+FFFC for each token |
| `NavigatorFilterControlBar()` (RuntimeViewerUI, an AppKitPlus `NSFilterControlBar`) | an `HStackView` of buttons and a search field at the bottom of a sidebar page |
| `HorizontalSeparatorView()` (RuntimeViewerUI) | an `NSBox` with `boxType = .separator` for a horizontal line |
| `final class XxxView: LayerBackedView` | `final class XxxView: NSView` (when it needs `cornerRadius` / border / `backgroundColor` / shadow) |

**Never lay a plain separator box across a pane.** An `NSBox` separator decides for itself whether it is
horizontal or vertical, and one first asked for its size while its pane has no width takes itself for a
vertical line: the layout engine keeps `width == 1` at a hugging priority of 750 for it, and nothing ever
invalidates that. Pinned to both edges of the sidebar's first page, which launch lays out before the split
view has given the sidebar any width, it held the sidebar at its minimum width against every divider drag.
`HorizontalSeparatorView` reports no intrinsic width at all. Background:
`Documentations/ResolvedIssues/2026-10-20-sidebar-divider-locked-by-a-separator.md`.

**Building views**: `.then {}` returns the configured object, for assignment
(`let titleLabel = Label("Export").then { $0.font = .systemFont(ofSize: 18, weight: .semibold) }`);
`.do {}` mutates an already-declared one in place. Subviews go in with the `hierarchy {}` result builder,
NOT `addSubview`; stacks use the result-builder initializers. **All layout uses SnapKit**, with the
constraints grouped together after `hierarchy {}`.

<important if="you are using or changing a filter field, a filter bar, a pop-up path control, or the Find page's query field">

### Filter fields, filter bars and pop-up paths come from AppKitPlus

`NSFilterSearchField`, `NSFilterControlBar` and `NSPopUpPathControl` are ports of Xcode's own
`DVTSearchField`, `DVTFilterControlBar` and `DVTPathControl`; RuntimeViewer keeps no copies of its own any
more (UIFoundation's `FilterSearchField` went with its `FilterUI` trait; the old `PopUpPathControl` and
`ItemPopUpButton` were deleted). Background: `Documentations/Evolutions/0032-appkitplus-filter-and-path-controls.md`.

- The bar at the bottom of a sidebar page is a `NavigatorFilterControlBar` (RuntimeViewerUI): AppKitPlus's
  `NSFilterControlBar`, taken for a bar by the list's scroll pocket — a plain `NSFilterControlBar` there
  loses that without a sign; see *Navigator Pages Run Under Their Bars*. Give it the page's field as
  `filterField`, put the buttons beside the field in it as `NSFilterControlBarItem`s, and pin it to the
  edges: its intrinsic height carries the margins around the field. Set `controlSize` on the bar, never on
  its field: the bar sets the field's size whenever it takes the field or changes size.
- An item with a menu pops the menu up as a pull-down `NSPopUpButton` does: below the item, or above it
  when the window is at the bottom of the screen. **Item 0 of the menu is the pull-down's face and is
  never listed**, so a menu starts with an empty item, or its first entry goes missing; the item shows its
  own `image`, not item 0's. `ChoiceFilterControlBarItem` (RuntimeViewerUI) is the one for a choice of one
  case or none, such as the filter mode, and puts the face in itself. An item without a menu sends its
  action from its button on the bar, and that button is the view to show a popover from. An item has no
  tint: to show it as active, swap in a symbol coloured with the accent colour, which the bar keeps from
  AppKitPlus 0.10.1 on.
- Add a filter toggle with `addFilterButton(with:alternateImage:toolTip:accessibilityLabel:)` and leave its
  frame alone: the field lays its buttons out itself, and a constraint on one breaks that.
- Setting a field's `controlSize` also sets its `font`, to that size's system font, as Xcode does — in a
  bar, setting the bar's does. A field that needs another font sets it afterwards.
- Work in progress shows as the field's own `progress`, never as a spinner laid over the field.
- `NSPopUpPathControl` selects the chosen item before it tells its delegate. The Find page's mode path is
  the view model's to decide, so `FindModePathControlAdapter` puts the view model's path back in
  `popUpPathControl(_:didSelect:)` and only reports the choice. A path that an owner decides needs the
  same, or the control shows the bare chosen item for a moment.
- The Find page's query field is an `NSFindPatternSearchField`, whose content is a `FindQueryTerm`. A term
  with find patterns goes to the engine as a regular expression bounded by the engine's own identifier
  boundaries (`RuntimeTextPattern.regularExpression(_:boundedAs:)`), never ICU's `\b`, so a match style
  means the same with patterns and without; patterns can be inserted in Text mode alone
  (`allowsPatternInsertion`). Its magnifying glass's menu — Insert Pattern and the recent queries, kept
  per source in `AppDefaults.findRecentQueriesByScope` — is built by `FindQueryFieldMenuAdapter`, the
  field's delegate. Background: `Documentations/Evolutions/0050-find-patterns-and-recent-queries.md`.

</important>

### Layer-backed views

Any custom AppKit view that needs layer-level visuals (rounded corners, border, background colour,
shadow) MUST inherit `UIFoundationAppKit.LayerBackedView`, never raw `NSView` with hand-rolled
`wantsLayer = true` + `layer?.cornerRadius / layer?.borderColor / layer?.backgroundColor = ....cgColor`.
The base class already sets `wantsLayer` + `layerContentsRedrawPolicy = .onSetNeedsDisplay` and
centralizes everything in `updateLayer()`, so:

- Assign the exposed `NSColor?` properties directly — `backgroundColor = NSColor(light:dark:)`,
  `borderColor = ...` — **without** `.cgColor`. Dynamic colours re-resolve on appearance change
  automatically; do NOT override `viewDidChangeEffectiveAppearance` for them.
- One-time setup goes in `override func setup()` (called by `commonInit`); first-layout work goes in
  `override func firstLayout()`. Don't repeat `wantsLayer = true` in `init`.
- Available properties: `cornerRadius`, `borderWidth`, `borderColor`, `borderPositions`, `borderLocation`,
  `borderInsets`, `backgroundColor`, `shadowColor`, `shadowOpacity`, `shadowOffset`, `shadowRadius`,
  `shadowPath`.
- **Gotcha — `borderPositions` defaults to `[]`, so the border won't render** even with a non-zero
  `borderWidth` and a non-nil `borderColor`: a full rounded border needs `borderPositions = .all`.
- **Gotcha — a plain `NSView` has no `backgroundColor` of ours.** AppKitPlus gives every `NSView` a
  `backgroundColor` through an Objective-C category whose header is internal, so the app reaches it by
  key-value coding as `view._backgroundColor` (`NavigationTransitionBackdropController.swift`). Keep that
  bridge under a different name: while it was an `NSView` extension called `backgroundColor`, an
  unqualified `backgroundColor` inside a `LayerBackedView` subclass resolved to it instead of to the layer
  renderer's own property, and the background never showed. Use `_backgroundColor` only on plain views
  such as `BaseViewController.containerView`; a `LayerBackedView` — `BaseViewController`'s root
  `contentView` included — takes plain `backgroundColor`, and its renderer rewrites the layer's background
  on every `updateLayer`, so a colour set on it by key-value coding does not stay.

### Loading placeholders

Use `SkeletonPlaceholderView` (RuntimeViewerUI) — `SkeletonPlaceholderView.runtimeObjectList()` for a
list of `RuntimeObjectCellView` rows — driven by the state enum from *ViewModels*: on `.loading` set
`isPresentingPlaceholder = true` and hide the real content; on `.loaded` set it back to `false` and show
the content (hidden when it is empty).

- It **replaces** content, it does not overlay it: while it is presented the call site MUST hide the real
  subviews, otherwise the previous object's data shows through the gaps between bars. Hiding alone is not
  always enough — a hidden `NSView` still contributes its size to Auto Layout, so also clear stale text
  (or put the two in an `NSStackView`, which detaches hidden arranged subviews).
- `isPresentingPlaceholder` owns both `isHidden` and the pulse animation; never set `isHidden` directly.
- Add a preset (like `runtimeObjectList`) rather than composing `Row`/`Bar` at the call site. Use
  `Bar.Width.points` when the host container hugs its content (there is no width to take a fraction of),
  `.fraction` when the container's width is externally fixed.
- Do **not** use `NSView.showSkeleton(using:)` for this. That one is a translucent shimmer *overlay* —
  stale content remains visible underneath and its 0.35s fade-in itself reads as a flash.

## Tables and Outlines

When a table or outline displays Rx-driven data, **always** use the `rx.items` / `rx.nodes` adapter. Never
hand-roll an `NSTableViewDataSource` / `NSOutlineViewDataSource` (or pair `target` / `action` with manual
cell-reuse code) for data already produced by an Rx pipeline.

1. **Creation** — the `scrollableTableView()` factory from UIFoundation:
   `private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()`.
   For multi-column tables, use `NSTableView.scrollableTableView()` and add the columns yourself;
   `SingleColumnTableView` already installs the default column.
2. **Navigation lists** — when a list's only interaction is "click a row to go somewhere" (the Inspector's
   Relationships and Specializations panes), build it with `SelfSizingTableView.scrollableNavigationListTableView()`
   (RuntimeViewerUI) instead. It applies two settings that fix **different** flickers, and both are
   load-bearing:
   - `refusesFirstResponder = true` leaves keyboard focus where it was. `NSTableRowView.isEmphasized` is
     false whenever the owning table view is not first responder, so a click that takes focus — only for
     the app to hand it straight back — repaints the selection of the view the user is actually watching
     (the sidebar) in the inactive grey.
   - `selectionHighlightStyle = .none` removes *this* list's own highlight. Refusing first responder blocks
     focus, not selection: AppKit still selects the clicked row and paints it in the unemphasized grey for
     the frame before the navigation replaces the list.

   Assign `selectionHighlightStyle` **after** `style` — setting `NSTableView.style` resets it, so the
   reverse order silently does nothing. Reach for the factory only where nothing reads the selection:
   `itemClicked()` reports `clickedRow` and is unaffected, but `itemSelected()` / `modelSelected()` /
   `selectedRow` are, so a picker whose highlight marks the current candidate
   (`SpecializationTypePickerViewController`), or a list whose selection *is* the state
   (`SidebarRootViewController`), keeps its own highlight.
3. **Binding** — drive `tableView.rx.items` (or `outlineView.rx.nodes`) with the model driver and a
   cell-builder closure:
   `output.nodes.drive(outlineView.rx.nodes) { (outlineView: NSOutlineView, _: NSTableColumn?, node: NodeViewModel) -> NSView? in … }`;
   the table form's closure also gets the row index.
4. **Cell reuse** — `tableView.box.makeView(ofClass:)` / `outlineView.box.makeView(ofClass:)`
   (UIFoundationToolbox) handles identifier registration, recycling and fresh instantiation. **Never**
   write `tableView.makeView(withIdentifier:owner:) as? NSTableCellView` casts with a hand-built fallback.
   Pass a custom builder when the cell needs non-default initialization:
   `outlineView.box.makeView(ofClass: SidebarRuntimeObjectCellView.self) { .init(forOpenQuickly: false) }`.
5. **Cell views** — a `fileprivate final class` nested inside a controller extension, inheriting
   `TableCellView` (UIFoundationAppKit) so `setup()` and the auto-set identifier come for free. Lay out in
   `setup()`; bind in `bind(to:)`, which starts with `rx.disposeBag = DisposeBag()` to drop the previous
   row's bindings. Reserve `configure(with:)` for purely static cells whose cell ViewModel has no
   `@RxObserved` properties.
6. **Click / selection events** — derive from `tableView.rx.itemClicked()` / `tableView.rx.modelSelected()` /
   `outlineView.rx.modelDoubleClicked()` instead of `target` + `@objc` plumbing. A click maps to its model
   with `try? tableView.rx.model(at: index.row)` once `index.row` is checked against
   `0..<tableView.numberOfRows`, then `.asSignal(onErrorSignalWith: .empty())`.
7. **Optional `NSTableViewDelegate` / `NSOutlineViewDelegate` methods** (`shouldSelectRow`, persistence
   helpers, …) — forward them with
   `tableView.rx.setDelegate(self)` / `outlineView.rx.setDelegate(delegate)` and implement them in an
   extension. The adapter owns the data source and the required-method delegate proxy, and forwards
   optional methods to the delegate you set.

### Cell ViewModels

- **Wrap each row's domain model in a per-cell `XxxCellViewModel`** (à la `SidebarRuntimeObjectCellViewModel`,
  `SidebarRootCellViewModel`, `InspectorSwiftSpecializationCellViewModel`), declared
  `public final class … : NSObject, @unchecked Sendable` under the relevant `RuntimeViewerApplication`
  subfolder, holding the model as a stored `let`. The parent ViewModel's `Input` / `Output` traffic in
  cell ViewModels, not in raw models.
- **Everything a row shows goes into one `Appearance` struct behind a single `@RxObserved` — never one
  `@RxObserved` per icon, label or status.** A cell ViewModel exists once per row, and these lists run to
  thousands of rows. An `@RxObserved` costs only its value until its `$property` is touched, but
  `bind(to:)` touches every one it binds: each becomes a `BehaviorRelay` with an `NSRecursiveLock` of its
  own for as long as the cell ViewModel lives, and each `asDriver()` adds a share-replay operator with
  another lock while the row is on screen. Folding the sidebar's five into one took the process from about
  125,000 locks to 42,000 after scrolling through every object in SwiftUI
  (`Documentations/Evolutions/0005-cellvm-appearance-single-observed.md`). `SidebarRootCellViewModel` and
  `ReportCellViewModel` are the references.
  - **Publish once per change.** Build the new struct and assign it once, and only when it differs
    (`Appearance` is `Equatable`). The macro generates a plain getter and setter, so `appearance.title = …`
    field by field sends one event per statement.
  - **The cell binds `$appearance` once** and applies it in one place. When the appearance changes many
    times a second (a row showing progress), set each part only when it differs, as `ReportCellView` does.
  - **State nothing displays stays a plain property.** A flag only the filter reads
    (`ReportCellViewModel.isInProgress`) has no observer to serve.
  - **A cell ViewModel subscribes to nothing in `init`.** A row that observes shared state itself — a
    selection set, a progress stream — builds its relay and its subscription for every row, on screen or
    not. The parent ViewModel keeps its rows and pushes the change into them through an `update(…)`, the
    way the batch export picker does: `BatchExportingImageSelectionViewModel` hands every new selection to
    `BatchExportingImageTree.updateSelection(_:)`, which recomputes the checkbox of each row shown and
    assigns a row's one `@RxObserved`, `selection`, only when it changed.
- **`Differentiable` conformance** (DifferenceKit) — every model `rx.items` / `rx.nodes` displays conforms.
  Conform the **cell ViewModel**, not the raw domain type — never write
  `extension RuntimeObject: @retroactive Differentiable {}` on a core type, since retroactive conformances
  on shared models risk collisions across modules. Pick a `differenceIdentifier` that stays stable across
  rebuilds (typically the underlying domain object or its id) and gate the conformance behind
  `#if canImport(AppKit) && !targetEnvironment(macCatalyst)`, as the sidebar does. A cell ViewModel that
  owns no state beyond its `Hashable` domain object may use an empty `extension XxxCellViewModel: Differentiable {}` —
  DifferenceKit synthesizes `differenceIdentifier = self` / `isContentEqual = ==` from `Hashable + Equatable`.
- **Value-type outline trees** (a `struct` node that carries its `children`, such as `ReportNode`) follow
  RxAppKit's contract since 0.6.0: `==` and `hash(into:)` use the identifier alone, and
  `isContentEqual(to:)` compares the whole subtree recursively. The reload adapter (`rx.nodes(options: [])`)
  asks `isContentEqual` of the first level only and reloads nothing when every root answers yes, so a
  shallow answer swallows every change below it; and `NSOutlineView` keeps a row expanded across
  `reloadData()` only when the new item is `==` to the old one, so a synthesized whole-subtree `==`
  collapses every row whose subtree changed. When the rows' cells are bound to cell ViewModels kept across
  rebuilds, compare those by identity in `isContentEqual` too, so a row that got a new cell ViewModel is
  reloaded and its cell rebinds. `ReportOutlineBindingTests` pins all three on a real outline.

<important if="a list can hold thousands of rows, or you are touching DifferentiableBox or Open Quickly's cell ViewModels">

**Lazy cell ViewModels for large data sets.** When eager per-row cell ViewModel construction dominates
main-thread time (N ≥ ~1k rows, popovers and pickers over global type or symbol indexes), drive
`rx.items` / `rx.nodes` with `DifferentiableBox<Model>` (RuntimeViewerArchitectures) — a value-type box
that adapts any `Hashable` domain model to DifferenceKit's `Differentiable`, so the driver array carries
cheap identity elements — and construct the cell ViewModel inside the cell builder closure. Take that
form iff **all three** hold; otherwise stay on the eager 1:1 pattern:

1. The cell ViewModel's state is *fully determined at init time* from the model alone — no `@RxObserved`
   properties that mutate after init, no Rx pipelines fed by external sources, no `Task { … }` async
   loading inside it.
2. The data set is large enough that eager construction is visible in Instruments (typically N ≥ 1k,
   confirmed by a signpost baseline).
3. There is no per-row UI state that cannot be derived from the model (expanded/collapsed flag,
   multi-select checkmark, drag-preview metadata). If you need such state, build a local `struct`
   conforming to `Differentiable` directly — do NOT add mutable fields onto `DifferentiableBox`.

Two different things get called "lazy" here, and the eligibility tree above governs only the first:

- **Stateless lazy (`DifferentiableBox`)** — the cell ViewModel is rebuilt inside the cell builder on
  *every* render, so nothing survives between renders. That is why the three conditions are absolute: a
  cell ViewModel with post-init `@RxObserved` mutation or an Rx subscription would silently lose it. The
  `SpecializationTypePicker` popover is the canonical case (10k+ candidates when a generic parameter has
  no constraint); `SpecializationTypePickerViewModel` and `SpecializationTypePickerViewController` show
  both halves.
- **Lazily materialized behind a warm cache** — the driver array still carries fully built cell
  ViewModels, but each is constructed on first match and kept in a map for the rest of the session, so
  subscription identity and post-init state survive. Open Quickly uses this to avoid building a cell
  ViewModel per row of a 14k-object image; see `SidebarRuntimeObjectListViewModel.openQuicklyCellViewModel(at:)`.

`SidebarRuntimeObjectCellViewModel` owns filter-aware attributed names, so it fails the eligibility tree
and must never take the first form — but it is the type Open Quickly materializes in the second form,
precisely because the cache means it is never *re*constructed. Inspector cell ViewModels
(`InspectorSwiftSpecializationCellViewModel`, `InspectorRelationshipsCellViewModel`) stay eager on both
counts: their row counts are low enough that neither form pays for itself. Reach for either form only
once eager construction is measurably hurting — both trade a memo, and the invalidation it needs, for the
allocation they save. `DifferentiableBox<Model>.differenceIdentifier == model`, so DifferenceKit treats
two boxes as the same row iff their models are `==`: make `Model`'s equality a stable domain primary key,
not presentation-only data, or the diff spuriously triggers updates. `DifferentiableBox` itself is fully
`Hashable` even on UIKit / Catalyst; its `Differentiable` conformance is gated behind
`#if canImport(AppKit) && !targetEnvironment(macCatalyst)`.

</important>

<important if="you are changing a row's tags, RuntimeObjectCellView, or a popover anchored at a row">

### Row tags, and a popover anchored at one

`RuntimeObjectCellView` puts its icons first and any tags last: `RuntimeObjectCellAppearance.tags`
(`RuntimeObjectCellTag`) is published with the rest of the row, and each tag is a `TagButton`
(RuntimeViewerUI) at the row's trailing edge; the title truncates before a tag does. What holds the tags
there is the tag stack view's own hugging priority (`.box.hugging(h:)`, set above the text stack's default
`.defaultLow`): a stack view has no intrinsic size, so `.box.contentHugging` does nothing for it, and with
both stacks at the default Auto Layout widened either one. A tag that is not clickable takes no part in
hit-testing, so the click goes to the row (Open Quickly's tags). A clickable tag reports through the
cell's `tagClicked`; the list's cell provider pairs it with the row it bound and hands that to the view
model as data, and the popover about the row is anchored as *Routes carry no views* describes for rows.
The tags are `Local`, then `Private`. `Private` shows for an object whose `privateDeclarations` is not
empty, and its popover shows each discriminator with the source file the engine recovers for it
(`RuntimeEngine.privateDeclarationSourceFiles(forDiscriminators:inImage:)`). `Local`, never clickable,
shows for a type declared in a function or closure body (`RuntimeObject.Properties.isLocalType`;
`isPositionNamedLocalType` when the binary names no function for it). **The logic behind both lives in
MachOSwiftSection; RuntimeViewer only shows what it gets.** Which private declarations a name reads
(`DemanglingNode.privateDeclarations`), the name a local type is listed under
(`DefinitionName.localTypeDisplayName`), whether a type is local (`localTypeNaming`), and the source-file
search with its generated list of known file names (`PrivateDiscriminatorSourceFileIndex`, in the
`SwiftPrivateDiscriminators` product) are all MachOSwiftSection's; the engine holds one index per image
and answers the command. Do not parse a printed name for any of it, and do not reimplement a rule here —
change it there. Background: `Documentations/Evolutions/0031-private-discriminator-tag.md` and
MachOSwiftSection's evolution 0063 (`0063-private-declarations.md`).

</important>

## Coordinators and Routes

- **Route enums** carry `@AssociatedValue(.public)` and `@CaseCheckable(.public)`:
  `public enum MyRoute: Routable { case root; case detail(RuntimeObject); case dismiss }`.
- **ViewControllers and their ViewModels are created in the coordinator's `prepareTransition`**, never in
  a ViewController: build both, call `viewController.setupBindings(for: viewModel)`, and return the
  transition (`.presentOnRoot(viewController, mode: .asSheet)`, …).
- **Child to parent**: a nested `protocol Delegate: AnyObject` in the child coordinator
  (`func sidebarCoordinator(_ coordinator: SidebarCoordinator, completeTransition route: SidebarRoute)`),
  held as `weak var delegate: Delegate?` and implemented by the parent
  (`extension MainCoordinator: SidebarCoordinator.Delegate`).

**Routes carry no views** — a route's associated values never include an AppKit or UIKit type: no
`NSView` / `NSButton` sender, no `NSWindow`, `NSEvent` or `NSMenu`. The same goes for a ViewModel's
`Input`, which is where such a value would come from: a button press is a `Signal<Void>`, never a
`Signal<NSView>`. A popover that needs an anchor gets it in the coordinator's `prepareTransition`,
which asks the view layer, and returns `.none()` when the anchor is not on screen. Three shapes exist:

- A fixed control the coordinator can reach — `MainCoordinator.popoverAnchorView(of:)` takes the
  toolbar item's button for the Generation Options and MCP status popovers.
- A control the view controller holds — the controller exposes it, as
  `SidebarRuntimeObjectViewController.filterScopeAnchorView` does for the scope popover.
  `NSFilterControlBarItem` hands out its button only as the sender of its action, so that controller
  keeps the button from the last press.
- A row — the route carries the row, and the coordinator asks the view controller for the view in it
  (`anchorView(forTag:of:)`); see *Row tags, and a popover anchored at one*.

Background: `Documentations/Evolutions/0048-routes-carry-no-views.md`.

<important if="you are changing AppDelegate, or adding app-wide behaviour at launch or quit, a menu, an app-level observer or alert">

## AppDelegate and the Lifecycle Controllers

**AppDelegate is a dispatch shell, not a service container.** Treat it like a router that translates app
lifecycle into one-line calls on injected services.
`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift` is the reference: keep it the
shape it has.

**Allowed in AppDelegate** (and nothing else):
- Lifecycle hooks (`applicationDidFinishLaunching`, `applicationWillTerminate`, `applicationSupportsSecureRestorableState`, `applicationShouldTerminateAfterLastWindowClosed`, `application(_:open:)`, …)
- `@Dependency(\.xxx)` declarations for the controllers/services it dispatches to
- `@objc` action methods that immediately delegate to a router or injected service (one line each). The app has no nib, so these are menu actions reached through the responder chain, not Interface Builder connections
- One-line `start()` / `install()` / `stop()` / `checkOnLaunch()` calls on injected services
- Compile-time flag toggles like `runtimeViewerIsARM64EVariant = true` and one-shot fixes like `NSToolbarItemViewerOverflowFix.install()`
- The `@main` `static func main()`: pre-main one-shot fixes, then set the delegate, assign `MainMenuController`'s menu, and `run()` — nothing else (see below)

**Forbidden in AppDelegate**:
- `@objc` action handlers with bodies (extract to a controller's `@objc` method)
- `Task { … }` blocks doing work (push the work into a service method)
- `NSMenu` / `NSMenuItem` construction (the main menu is `MainMenuController`'s; anything added to it afterwards goes in a `XxxMenuController.install()`)
- `NSAlert` / `NSSavePanel` / `NSOpenPanel` flows (extract to the responsible controller)
- `observe { … }` / `withObservationTracking { … }` blocks (extract to a controller that owns the `ObserveToken`)
- Singleton bootstrapping logic, version checks, file I/O, log export — all belong to dedicated controllers

**The pattern** — every new lifecycle responsibility is a new `@MainActor` controller class in
`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`, registered as a `@Dependency` singleton (root
`AGENTS.md`, *Singletons & Dependency Injection*). Current examples:
- `AppearanceController` — observes `settings.general.appearance` and updates `NSApp.appearance`
- `DebugMenuController` — installs the Debug menu and owns the Export Logs flow
- `HelperServiceVersionChecker` — runs the helper version probe and presents reinstall alerts
- `UpdaterService` — owns the Sparkle updater lifecycle
- `MainMenuController` — assembles the main menu in code (the replacement for `MainMenu.xib`)
- `WindowLifecycleController` — answers `applicationShouldHandleReopen` / `applicationShouldTerminateAfterLastWindowClosed`
- `CommandLineHostController` — makes the running app the CLI host: asks a standalone host to leave on launch, serves the socket, removes its files on quit
- `SettingsLifecycleController` — loads the settings at launch and flushes them at termination (root `AGENTS.md`, *Settings Integration*)

**One-shot fixes that must beat the main menu** go in `AppDelegate.main()` (`AppDelegate` carries `@main`
and supplies its own `static func main()`), before `NSApplication.mainMenu` is assigned — not in a
lifecycle callback, which runs too late. `SystemAutoFillMenuSuppression` is the standing example: the
default it registers is read, and then cached for the process, the first time AppKit customizes the main
menu. A fix that lands there must say in a comment why, or the next reader will move it and it will
silently stop working. `RuntimeInjection.install()` is called there too, before any engine connects
(root `AGENTS.md`, *Injection commands*).

If a lifecycle responsibility doesn't fit one of these one-liners, **make it a new controller before
touching AppDelegate**.

</important>

<important if="you are adding or changing a sidebar or inspector page, a tab switcher, a filter bar, or anything laid over a list's scroll view">

## Navigator Pages Run Under Their Bars (macOS 26 and later)

The sidebar is laid out the way Xcode lays out its navigator area: a page's list runs the whole height of
the sidebar — under the toolbar, under the tab switcher's segmented control and under the filter bar — and
those bars float over it. The list keeps its content clear of them through safe area, not through
constraints, and AppKit draws the scroll edge effect (the blur where content scrolls under a bar, which
AppKit calls a scroll pocket) over that same safe area. Before macOS 26 the pages stay stacked.
Background, with the reverse-engineered addresses: `Documentations/Evolutions/0052-xcode-navigator-overlay-bars.md`.

- `TabViewController.pageLayout` picks the layout per switcher: `.underSegmentedControl` for the sidebar's
  two (`SidebarRootTabViewController`, `SidebarRuntimeObjectTabViewController`), `.belowSegmentedControl` —
  the default — for the inspector's, which Xcode stacks too. Under `.underSegmentedControl` the tab view
  fills the view, the bar holding the segmented control is drawn over it, and a `FloatingBarSafeAreaLayout`
  (RuntimeViewerUI) writes the bar's height (28 at `.large`) into `tabView.additionalSafeAreaInsets.top`
  whenever the bar's frame changes. **Never from the switcher's `viewDidLayout`**: AppKit calls it before
  it lays out anything below the controller's view's direct subviews, so the bar still has the frame of
  the pass before, and a page pushed onto the sidebar may get no second pass — its list then starts under
  the bar. `TabSwitcherBarSafeAreaTests` covers it; background:
  `Documentations/ResolvedIssues/2026-10-15-sidebar-list-starts-under-the-tab-switcher-bar.md`.
- **Every page of every switcher starts its content 8 points below the segmented control**
  (`TabViewController.pageTopSpacing`, which is `NavigatorScrollViewLayout.topContentInsetBeyondSafeArea`,
  so every such gap follows that one value). A page stacked below the control — every page before macOS
  26, the inspector's on every system — gets the gap from the switcher and starts its own content at its
  top edge, with no top margin of its own. A page running under the bar gets it from its list's content
  inset, and the Find page's query area from a constraint on `pageTopSpacing`.
- A page shown in a sidebar switcher lets its list's scroll view reach all four edges of the page and
  hands the list to a `NavigatorScrollViewLayout` (RuntimeViewerUI), never a container inset or a
  constraint to a bar. The four page base classes (`SidebarRootViewController`,
  `SidebarRuntimeObjectViewController`, `FindViewController`, `ReportViewController`) keep
  `BaseViewController`'s `contentInsets`, which are zero, for this reason. A scroll view that stops below
  the titlebar is not registered with the window, so it gets no top pocket, and its rows are cut off at
  the bar instead of scrolling under it.
- `NavigatorScrollViewLayout` takes the views that float over the list's edges — the filter bar as
  `bottomOverlayViews`, the Find page's query area and summary row as `topOverlayViews` — turns the depth
  they cover into the scroll view's own `additionalSafeAreaInsets`, and sets the clip view's
  `contentInsets` to the safe area plus 8 points at the top, as Xcode does, following both by itself. It
  makes every scroll pocket call too — it registers the overlays as pocket containers
  (`-[NSScrollView registerPocketContainer:onEdge:]`, through UIFoundation's `NSScrollView.box`), keeps
  both edges always shown (`alwaysShownPocketEdges = 3`) and, on macOS 26 only, sets style 2 on both edges
  as Xcode does there — so nothing else touches a page's scroll view. Add the scroll view before those
  views, so that they draw and take clicks above it; leave the 1-point separators out from macOS 26 — the
  edge effect replaces them — by making them with `HorizontalSeparatorView.makeForStackedNavigatorLayout()`,
  which returns `nil` there: never keep one hidden, since a hidden view still takes part in Auto Layout
  (*Never lay a plain separator box across a pane*, under *Views*); centre empty-state text and placeholders
  in the safe area (`scrollView.safeAreaLayoutGuide`), not in the scroll view.
- Keep the scroll view's own `automaticallyAdjustsContentInsets` on, and leave the clip view's insets, its
  `automaticallyAdjustsContentInsets` and the scroll view's `additionalSafeAreaInsets` to the layout. AppKit
  sizes the bottom scroll pocket by the scroll view's own bottom content inset, not the clip view's
  (measured on macOS 27.2), so a scroll view whose automatic insets are off gets no bottom edge effect even
  though its rows still clear the bar.
- The floating views answer AppKit's `_scrollPocketElementStyle` with 2, the value Xcode's bars answer:
  the filter bar is a `NavigatorFilterControlBar`, and the Find page's query area and summary row and the
  tab switcher's bar are `ScrollPocketBarView`s (both RuntimeViewerUI). A plain `NSFilterControlBar` or
  `NSView` in their place still gets the edge effect, only not as a bar, and nothing shows that anything
  is missing.
- The tab switcher's bar belongs to `TabViewController`, not to the page, and reaches the list through
  `NavigatorTabPage`: the switcher sets `tabSwitcherOverlayViews` to the bar on the page on screen and back
  to none on the page before, at the end of every path that changes the selection — its tab view has no
  delegate, so nothing reports a selection — and the page passes them to its layout as
  `inheritedTopOverlayViews`, which are registered but add no safe area: the bar's height already arrives
  through `tabView.additionalSafeAreaInsets`. One scroll view holds the bar at a time. A new page class
  shown in a sidebar switcher adopts `NavigatorTabPage` and keeps the value until it makes its layout,
  because `NSTabViewItem(viewController:)` loads a page's view only when it is first shown. The
  inspector's switcher does none of this.

</important>

<important if="you are diagnosing flicker, a selection highlight that turns grey, keyboard focus in a list, or a context menu that will not open">

## Diagnosing UI Flicker

**Measure the frames before changing anything.** Flicker is a one-to-three-frame artifact; reading the
code and reasoning about what "should" happen has repeatedly produced confident, wrong answers here. Ask
for a screen recording, export **every** frame with `AVAssetReader` (time-point sampling is too coarse and
misses the artifact outright), then pixel-diff consecutive frames and report changed-pixel count plus the
y-range of the changed rows. Which pixels changed on which frame is the thing inference cannot give you.

Two causes account for every flicker found so far — check them first:

- **A highlight goes grey and then comes back.** `NSTableRowView.isEmphasized` is false whenever the
  owning table view is not the first responder, which draws the selection in the inactive grey. A click
  that moves focus into a click-to-navigate list greys out the selection in whatever view the user is
  actually watching, for focus the app hands straight back. Build such lists with
  `SelfSizingTableView.scrollableNavigationListTableView()` — see *Navigation lists* under *Tables and
  Outlines*. Mouse clicks, row selection and `itemClicked` all keep working.
- **A scroll result and a selection/content result land on different frames.** `NSOutlineView`
  materializes a row view only as the row scrolls into view, and applies the emphasized selection style
  after that. **Always scroll a row into view before selecting it** — never the reverse — and force the
  layout that the raw clip-view scroll would otherwise defer.
  `SidebarRuntimeObjectViewController.selectRowBringingIntoView(_:)` is the reference implementation;
  route new call sites through it rather than pairing `selectRowIndexes` with `scrollRowToVisible` by hand.

Full write-up, including the frame table that pinned it down:
`Documentations/ResolvedIssues/2026-08-05-sidebar-selection-highlight-flicker.md`.

**A selection that stays grey in a key window, and a context menu that will not open, is not flicker.**
It means focus is parked on a plain container *above* the list. While an ancestor container is first
responder, a right-click on a cell's text does not open the table's menu, and on macOS 27 a left click no
longer moves focus into the table either: macOS 27 handles table clicks with gesture recognizers,
whatever SDK the app links against, and they take focus only for Sidecar touches. macOS 26 hides all of
it, because there `-[NSTableView mouseDown:]` takes focus on every click — so reproduce on macOS 27, and do
not read anything into re-stamping the binary's SDK. AppKitPlus's navigation controller hands the first
responder to the page's `preferredFirstResponder` at the end of every push, pop and `set`, so a page that
holds a list overrides it to return the list, only while it is in the window — `TabViewController`
forwards it to the tab on screen. Reproduce this with a real navigation, not by making the outline first
responder first: that skips the very state that triggers it. Write-up:
`Documentations/ResolvedIssues/2026-09-24-sidebar-focus-parked-on-a-navigation-container.md`.

**`StatefulOutlineView` carries two overrides that look removable and are not — keep both where they
are; their doc comments carry the evidence.** Its `mouseDown(with:)` override, whose body is only `super`,
keeps AppKit from installing its table gesture recognizers, so the outline stays on macOS 26's tracking
loop: on macOS 27 those recognizers move a single-selection list's selection with a drag only when
`allowsMultipleSelection` is on, and the loop also takes focus on every click. AppKit logs "Gesture
recognizer support has been disabled because NSTableView subclass … overrides either mouseDown: or
mouseDragged:" for each such outline — expected. Keep the `preferredFirstResponder` handover anyway, for
keyboard focus straight after a navigation and for the right-click case. Its `delegate` setter turns
AppKit's row height estimation off (UIFoundation's `box.estimatesRowHeights`, `AppleInternal` trait),
because `-[NSOutlineView setDelegate:]` turns it back on at every change of delegate — including the
nil-then-proxy resets RxCocoa's delegate proxy performs on its own; with estimation on, a reload (every
filter keystroke) or an expansion far down the list leaves rows at stale estimated positions and the next
scroll draws rows over them. The setter is the one safe place: switching discards the row geometry
without moving the row views already on screen, so never move it to `setupBindings` or anywhere after
rows are shown. `StatefulOutlineViewRowGeometryTests` fails if the estimation comes back. Write-ups:
`Documentations/ResolvedIssues/2026-09-25-single-selection-drag-stopped-following-the-pointer.md`,
`Documentations/ResolvedIssues/2026-09-27-sidebar-rows-drawn-over-each-other.md`.

</important>
