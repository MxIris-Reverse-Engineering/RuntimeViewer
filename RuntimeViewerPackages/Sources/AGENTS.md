# AGENTS.md — RuntimeViewerPackages sources

## The application layer: RuntimeViewerAppCore, RuntimeViewerAppUI and the facade

The apps' application layer is two targets and a facade
(`Documentations/Evolutions/draft-app-core-ui-split.md`):

- **`RuntimeViewerAppCore/`** holds the ViewModels, cell ViewModels, routes, `DocumentState` and the
  application logic. **Everything in it can be built and driven in a unit test, and no UI component
  appears in it**: no subclass or construction of a view, control, cell, menu, popover, window or view
  controller, no delegate, data source or adapter of a control, no coordinator. UI framework models are
  fine — `NSImage`, `NSColor`, `NSFont`, `NSAttributedString`, `NSEvent` and its modifier flags — and so
  are `Driver` / `Signal`, `@RxObserved` and `Router`.
- **`RuntimeViewerAppUI/`** holds the UI glue: the adapters that set up AppKit and AppKitPlus controls
  (`NavigatorTextFilterFieldAdapter`, the Find page's and the runtime source picker's), the jump bar's
  path items, the presenter that feeds the toolbar's activity view, `FindResultsPresentation.apply(to:)`.
  Code whose job is to drive a UI component goes here even when it can be tested; it depends on
  RuntimeViewerAppCore, never the other way round.
- **`RuntimeViewerApplication/`** is a facade that only re-exports the two; the apps link this one
  product and import this one module. Put no code in it. Package code and tests import the target they
  use, not the facade.

While the split lands, RuntimeViewerAppCore still depends on RuntimeViewerUI, RuntimeViewerSettingsUI and
AppKitPlus; the proposal's later steps take these out and add a test that fails on a UI component in
RuntimeViewerAppCore. Do not add new uses of them there in the meantime.

## The rest of the UI layer

`RuntimeViewerAppCore/` (ViewModels, cell ViewModels, routes, `DocumentState`), `RuntimeViewerAppUI/` and
`RuntimeViewerUI/` (AppKit views) are the shared half of the macOS app's UI layer, and follow its rules: **read
`RuntimeViewerUsingAppKit/AGENTS.md` before adding or changing a ViewModel, a cell ViewModel, a
`Differentiable` conformance, a route or a view here** — state as `@RxObserved`, one state enum for async
content, one `Appearance` per cell ViewModel, routes that carry no views, layer-backed views, the sidebar's
floating bars. The repository-wide rules, among them single-object interface fetches through
`documentState.interfaceCache` and the per-engine background work behind `DocumentState`, are in the
root `AGENTS.md`.

Several types in `RuntimeViewerUI/` carry behaviour that looks removable and is not. Their doc comments
say why, so read them before touching: `StatefulOutlineView` (the `mouseDown(with:)` override whose body is
only `super`, and the row height estimation switch in the `delegate` setter), `FloatingBarSafeAreaLayout`
and `NavigatorScrollViewLayout` (when the safe area is written, and the scroll pocket calls), and
`HorizontalSeparatorView` (the `intrinsicContentSize` override, which is the whole fix for a separator box
that holds a pane at its minimum width).

This file sits here rather than in a target's folder because SwiftPM reports any file it has no rule for
inside a target as unhandled — keep `AGENTS.md` and `CLAUDE.md` out of `Sources/<Target>/` and
`Tests/<Target>/`.
