# AGENTS.md — RuntimeViewerPackages sources

`RuntimeViewerApplication/` (ViewModels, cell ViewModels, routes, `DocumentState`) and `RuntimeViewerUI/`
(AppKit views) are the shared half of the macOS app's UI layer, and follow its rules: **read
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
