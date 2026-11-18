# AGENTS.md — RuntimeViewerPackages sources

## The application layer: RuntimeViewerAppCore, RuntimeViewerAppUI and the facade

The apps' application layer is two targets and a facade
(`Documentations/Evolutions/0091-app-core-ui-split.md`):

- **`RuntimeViewerAppCore/`** holds the ViewModels, cell ViewModels, routes, `DocumentState` and the
  application logic. **Everything in it can be built and driven in a unit test, and no UI component
  appears in it**: no subclass or construction of a view, control, cell, menu, popover, window or view
  controller, no delegate, data source or adapter of a control, no coordinator. `Driver` / `Signal`,
  `@RxObserved` and `Router` are fine. **AppKit's and UIKit's models are on their way out too**
  (`Documentations/Evolutions/draft-app-core-without-ui-models.md`, landing in four steps): AppCore does
  not import AppKit, UIKit or Cocoa and names no AppKit or UIKit type — not `NSImage`, `NSColor`,
  `NSFont`, `NSAttributedString`, `NSEvent` — but describes images, colours, row text and the content
  pane's text as values that RuntimeViewerAppUI resolves. Until the last step lands, the files still to be
  cleaned up are listed in `AppCoreBoundary.filesPendingCleanup`; never add one to the list, and take a
  file off it in the commit that cleans it up.
- **`RuntimeViewerAppUI/`** holds the UI glue: the adapters that set up AppKit and AppKitPlus controls
  (`NavigatorTextFilterFieldAdapter`, the Find page's and the runtime source picker's), the jump bar's
  path items, the presenter that feeds the toolbar's activity view, `FindResultsPresentation.apply(to:)`,
  the coordinator that opens the app's own windows, the transitions that drive AppKitPlus's navigation
  controller (`Transition+Navigation.swift`), the Find query field's content as a `FindQueryTerm` and
  back, and the live implementations of the services RuntimeViewerAppCore declares (below).
  Code whose job is to drive a UI component goes here even when it can be tested; it depends on
  RuntimeViewerAppCore, never the other way round.
- **`RuntimeViewerApplication/`** is a facade that only re-exports the two; the apps link this one
  product and import this one module. Put no code in it. Package code and tests import the target they
  use, not the facade.

**RuntimeViewerAppCore depends on no UI library**: not on RuntimeViewerUI or RuntimeViewerSettingsUI, not on
UIFoundation, SFSymbols or AppKitPlus, and neither does RuntimeViewerArchitectures beneath it. What it took
from them it has of its own: the `NSUIImage` / `NSUIColor` / `NSUIFont` aliases (`PlatformTypes.swift`;
UIFoundation's and SFSymbols' name the same types, so a file that sees several still compiles),
`NSAttributedString(rowText:fontSize:color:)` for a row's title, `SystemSymbol` for the system symbols it
draws (`SystemSymbolTests` loads every case) and `CustomSymbol` for the ones it ships in its own asset
catalog, `Resources/Symbols.xcassets` (the image kinds' symbols taken from Xcode, kept as version 6
templates so that macOS 15 reads them; `CustomSymbolTests` loads every case and checks the version),
the Xcode colours of `NSColor+Xcode.swift`, and the Find query
field's content as data: `FindQueryTerm` and `FindPattern`, with AppKitPlus's rules for the regular
expression a term makes and for its property list rewritten in `FindQueryTerm.swift`. **A change to those
rules in AppKitPlus is carried over by hand**: `FindPatternParityTests` runs both on the same input and fails
when they part, and the recent queries every earlier version stored must still read back
(`FindRecentQueriesTests`).

**`AppCoreBoundaryTests` holds RuntimeViewerAppCore to this**, because the compiler does not: SwiftPM lets a
target import any module the same build compiles, declared or not. It reads RuntimeViewerAppCore's sources
— comments and strings left out, every `#if` evaluated for macOS and for the iOS family — and reports, file
and line:

1. an import of a UI library: `RuntimeViewerUI`, `RuntimeViewerSettingsUI`, `RuntimeViewerAppUI`,
   `RuntimeViewerApplication`, SwiftUI, SnapKit, AppKitPlus, SFSymbols, `AppKitNavigation`,
   `UIKitNavigation`, or a module of UIFoundation other than `UIFoundationSettings`;
2. a type that inherits from `NSResponder`, `UIResponder`, a CocoaCoordinator or XCoordinator coordinator
   class, or an `NS` / `UI` class whose name ends in `View`, `ViewController`, `Window`, `WindowController`,
   `Control`, `Cell`, `Menu`, `MenuItem`, `Popover`, `Field`, `Bar` or `Button`; or that conforms to an
   `NS` / `UI` protocol ending in `Delegate` or `DataSource`, AppKitPlus's included;
3. a call to the initializer of one of those classes;
4. an import of AppKit, UIKit or Cocoa (a submodule such as `UIKit.UIGeometry` included);
5. any name spelled as AppKit's and UIKit's are — `NS` or `UI`, then a capital — other than the Foundation
   names in `AppCoreBoundary.allowedSystemPrefixedNames` (`NSRange`, `NSString`, `NSLock`, `NSObject`, …).
   `NSAttributedString` is reported although Foundation declares it: it carries fonts and colours. A
   Foundation name AppCore starts to use goes on that list without a reason.

Rules 4 and 5 skip the files in `AppCoreBoundary.filesPendingCleanup` until the proposal's step that
cleans each one up; a second test fails when a listed file no longer breaks them, so the list only
shrinks. It also walks the manifest from RuntimeViewerAppCore down through the package's targets beneath it
and fails on a UI library among their dependencies. The check reads names: it cannot follow a superclass
chain or a type alias, and system service protocols outside AppKit and UIKit
(`UNUserNotificationCenterDelegate`) pass. A line it reports that belongs here all the same goes in the
test's `allowedLines`, with the reason, and a third test fails when an allowance matches no reported line
any more. The only allowances are the iOS route's: `DocumentState`'s private selection router and empty
transition name `UIViewController` because XCoordinator's `Presentable` and `TransitionProtocol` do.

**A service whose live implementation needs a UI library, AppKit or UIKit is declared in RuntimeViewerAppCore
and implemented in RuntimeViewerAppUI**: opening the app's own windows (`appRouter`, implemented by
`AppCoordinator`), the engines' icons (`runtimeEngineIconProviding`, implemented by
`RuntimeEngineIconProvider`), drawing an object's icon (`runtimeObjectIconRendering`, implemented with
UIFoundation's `IDEIcon`), the copy commands' pasteboard (`pasteboardClient`, `PasteboardClient.general`) and
Show in Finder (`finderClient`, `FinderClient.workspace`). The pasteboard and the Finder give tests an inert
client that does nothing; `ViewModelTestEnvironment` swaps in recorders. How such a key is
written: root `AGENTS.md`, *Singletons & Dependency Injection*. `IDEIcon` keeps its images in a dictionary
without a lock, so object icons are drawn on the main thread only, and tests that draw them run on the main
actor.

**Every list of images takes a row's icon from `RuntimeImageKind`**: a node of the image tree by
`node.kind` (its own name), a place that lists one image by `RuntimeImageKind(ofImageAt:)` (the bundle
nearest to it on its path). Its colour is the kind's too, Xcode's for that kind of file: a list that can tint
a template draws `icon` with `contentTintColor` set to `iconColor`, which a selected row turns white as Xcode's
navigator does, and a place that draws an image as it is — the jump bar and its menus, the editor's tabs, the
history menu — takes `coloredIcon`. Never pick a colour for an image's icon anywhere else.
Background: `Documentations/Evolutions/0090-image-kind-icons.md`.

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
