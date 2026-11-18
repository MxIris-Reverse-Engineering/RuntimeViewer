# AGENTS.md — RuntimeViewerPackages sources

## The application layer: RuntimeViewerAppCore, RuntimeViewerAppUI and the facade

The apps' application layer is two targets and a facade
(`Documentations/Evolutions/0091-app-core-ui-split.md`):

- **`RuntimeViewerAppCore/`** holds the ViewModels, cell ViewModels, routes, `DocumentState` and the
  application logic — **every ViewModel of the apps; the macOS app target holds none**
  (`Documentations/Evolutions/0096-view-models-to-app-core.md`), and `AppTargetBoundaryTests` reads the
  app's sources and fails on a type there named as a view model or inheriting `ViewModel<…>`,
  `CellViewModel` or `ViewModelProtocol`. The macOS window's view models, routes and page states are wrapped
  in `#if os(macOS)`. **Everything in it can be built and driven in a unit test, and no UI component
  appears in it**: no subclass or construction of a view, control, cell, menu, popover, window or view
  controller, no delegate, data source or adapter of a control, no coordinator. `Driver` / `Signal`,
  `@RxObserved` and `Router` are fine. **No AppKit or UIKit model either**
  (`Documentations/Evolutions/0094-app-core-without-ui-models.md`): AppCore does not import AppKit,
  UIKit or Cocoa and names no AppKit or UIKit type — not `NSImage`, `NSColor`, `NSFont`,
  `NSAttributedString`, `NSEvent`, `NSPasteboard` — but describes images, colours, row text and the
  content pane's text as values that RuntimeViewerAppUI resolves, so every view model's state is a value.
  The one exception is the iOS route's `UIViewController`, which XCoordinator's protocols name.
- **`RuntimeViewerAppUI/`** holds the UI glue: the adapters that set up AppKit and AppKitPlus controls
  (`NavigatorTextFilterFieldAdapter`, the Find page's and the runtime source picker's), the jump bar's
  path items, the toolbar activity views' state made from RuntimeViewerAppCore's `ToolbarActivity`
  (`ToolbarActivityState.init(_:)`), `FindResultsPresentation.apply(to:)`,
  the coordinator that opens the app's own windows, the transitions that drive AppKitPlus's navigation
  controller (`Base/Transition+Navigation.swift`), the Find query field's content as a `FindQueryTerm` and
  back, and the live implementations of the services RuntimeViewerAppCore declares (below).
  Code whose job is to drive a UI component goes here even when it can be tested; it depends on
  RuntimeViewerAppCore, never the other way round.
- **`RuntimeViewerApplication/`** is a facade that only re-exports the two; the apps link this one
  product and import this one module. Put no code in it. Package code and tests import the target they
  use, not the facade.

**RuntimeViewerAppCore depends on no UI library**: not on RuntimeViewerUI or RuntimeViewerSettingsUI, not on
UIFoundation, SFSymbols or AppKitPlus, and neither does RuntimeViewerArchitectures beneath it. What it took
from them it has of its own: `SystemSymbol` naming the system symbols it shows, and the Find query
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

It also walks the manifest from RuntimeViewerAppCore down through the package's targets beneath it
and fails on a UI library among their dependencies. The check reads names: it cannot follow a superclass
chain or a type alias, and system service protocols outside AppKit and UIKit
(`UNUserNotificationCenterDelegate`) pass. A line it reports that belongs here all the same goes in the
test's `allowedLines`, with the reason, and a third test fails when an allowance matches no reported line
any more. The only allowances are the iOS route's: `DocumentState`'s private selection router and empty
transition name `UIViewController` because XCoordinator's `Presentable` and `TransitionProtocol` do.

**A service whose live implementation needs a UI library, AppKit or UIKit is declared in RuntimeViewerAppCore
and implemented in RuntimeViewerAppUI**: opening the app's own windows (`appRouter`, implemented by
`AppCoordinator`), the copy commands' pasteboard (`pasteboardClient`, `PasteboardClient.general`) and Show
in Finder (`finderClient`, `FinderClient.workspace`). The pasteboard and the Finder give tests an inert
client that does nothing; `ViewModelTestEnvironment` swaps in recorders. **A service implemented in a
package above this one is declared the same way**: the MCP status popover starts, stops and follows the app's
MCP server through `mcpServerClient` (`MCP/MCPServerClient.swift`), whose live value `RuntimeViewerMCPBridge`
supplies, because that package depends on RuntimeViewerAppCore and so this module cannot name its
`MCPService`; the key is `public`, since `package` does not reach another package, and the bridge's own
`MCPServerClientLiveTests` checks the live value. How such a key is written: root `AGENTS.md`,
*Singletons & Dependency Injection*.

**An icon or a colour RuntimeViewerAppCore shows is a value it describes, and RuntimeViewerAppUI draws it**
(`Presentation/IconDescriptor.swift`, `ColorDescriptor.swift`; drawn by `IconDescriptor.image` and
`ColorDescriptor.color` in AppUI's `Presentation/`): a system symbol (`SystemSymbol`, names only), a kind of
image, an object's glyph or a letter badge (`RuntimeObjectIcon.Glyph`, which AppCore picks and AppUI draws with
UIFoundation's `IDEIcon` through `runtimeObjectIconRendering`), one of the Find navigator's row symbols, or an
engine by its `engineID` (AppUI's `RuntimeEngineIconProvider.icon(forEngineID:)` and
`sourcePickerIcon(forEngineID:)` find it among the manager's engines, and for an engine the manager no longer
holds answer with the icon they last drew for it — what the runtime source picker shows for a window whose
engine went away). A view that draws engines' icons draws them again on the provider's
`recordedIconsChanged`: an injected device process's icon is recorded after its engine has been listed. A cell's `Appearance` carries the descriptors and the cell view draws them, on the main thread:
`IDEIcon` keeps its images in a dictionary without a lock, so tests that draw icons run on the main actor.
AppUI also keeps the drawing under the names AppCore used to have — `RuntimeImageKind.icon`, `iconColor`,
`coloredIcon`, `RuntimeObjectIcon.icon(for:)` — for the views that draw an image directly. `CustomSymbol`
and its asset catalog, `Resources/Symbols.xcassets` of RuntimeViewerAppUI (the image kinds' symbols taken from
Xcode, kept as version 6 templates so that macOS 15 reads them), live there too; `SystemSymbolTests` and
`CustomSymbolTests` in RuntimeViewerAppUITests load every case.

**A row's text is `RowText` — runs of roles, not fonts and colours** (`Presentation/RowText.swift`): the
name, a subtitle, what a filter did or did not match, a Find hit's line, an unresolved row; with the point
size the row is drawn at where it has one. The view draws it in its list's style,
`rowText.attributedString(in: .list)` or `.findResult(metrics)` (AppUI's `Presentation/RowText+AttributedString.swift`):
the list style is attribute for attribute what `NSAttributedString(rowText:fontSize:color:)` makes
(`RowTextAttributedStringTests`), and the Find style takes its fonts and colours from `FindResultCellStyle`,
which lives in AppUI with the Xcode colours of `Find/Results/NSColor+Xcode.swift`. A Find row's sizes — the
navigator's or the Inspector's References tab's — are its cell view's, not the row's: the view draws the
badges at `metrics.iconSize` (`IconDescriptor.image(size:)`).

**The content pane's text is a `ContentInterface`, and the theme is RuntimeViewerAppUI's.**
`ContentTextViewModel` fetches the interface and prepares it off the main thread — the semantic string,
the link and declared-member tables the panes look things up in by UTF-16 offset
(`linkedRuntimeObject(at:)`, `declaredMember(at:)`), the comment decorations and the macro expansions — and
knows no theme. The views theme it with AppUI's `ContentTextRenderer` (`ThemeProfile`, `ResolvedTheme` and
`resolvedThemeStream` live in AppUI's `Theme/`, `ContentInterface.attributedString(themedWith:)` beside the
renderer in its `Content/`), which re-themes on a theme change without a refetch. The renderer's `renderedText` is cold: the
SourceEditor pane colours the semantic runs itself and subscribes only `theme`, so it never builds an
attributed string. **A view that shows an interface reports it through `Input.interfaceDisplayed`** — the
`NSTextView` pane once the themed text is set, SourceEditor after `setSource`, iOS once the text is set —
and the view model's loading lasts until that report: a pane that never reported would leave its loading
plate up. A theme-only change, which the view model does not see, lights the plate through the renderer's
`delayedRendering`, which the `NSTextView` pane feeds into `BaseViewController.additionalCommonLoadingRelay`.
The `NSUIImage` / `NSUIColor` / `NSUIFont` aliases (`Extensions/PlatformTypes.swift`; UIFoundation's and SFSymbols'
name the same types, so a file that sees several still compiles) and `NSUIColor(light:dark:)` live in
AppUI too.

**Every list of images takes a row's icon from `RuntimeImageKind`**: a node of the image tree by
`node.kind` (its own name), a place that lists one image by `RuntimeImageKind(ofImageAt:)` (the bundle
nearest to it on its path). Its colour is the kind's too, Xcode's for that kind of file. A view model names
both as `IconDescriptor.imageKind(_:)` and `ColorDescriptor.imageKind(_:)`; a list that can tint a template
draws `icon` with `contentTintColor` set to `iconColor`, which a selected row turns white as Xcode's
navigator does, and a place that draws an image as it is — the jump bar and its menus, the editor's tabs, the
history menu — takes `coloredIcon` (all three in RuntimeViewerAppUI's `RuntimeImage/RuntimeImageKind+Icon.swift`).
Never pick a colour for an image's icon anywhere else.
Background: `Documentations/Evolutions/0090-image-kind-icons.md`.

## Where a file goes in RuntimeViewerAppCore and RuntimeViewerAppUI

(`Documentations/Evolutions/0095-app-layer-directory-layout.md`)

- **Nothing at a target's root.** Every file is in a directory named after a feature: the app's own folder
  name where the app has one (`App`, `Base`, `BatchExporting`, `Content`, `EditorArea`, `Exporting`, `Find`,
  `Inspector`, `Main`, `MCP`, `Reports`, `Sidebar/Root`, `Sidebar/RuntimeObject`, `Specialization`; without
  the space where the app's has one: `AttachToProcess` for `Attach Process`, `GenerationOptions` for
  `Generation Options`), otherwise what the directory holds (`Activity`, `BackgroundWork`, `ContextMenus`,
  `Document`, `Engine`, `Extensions`, `Filtering`, `Presentation`, `RuntimeImage`, `RuntimeObject`,
  `RuntimeSourcePicker`, `Storage`). `Find/` has `Query/`, `Scope/`, `Results/` and
  `CrossReferences/` below it; its root keeps only `FindViewModel`, `FindSession` and `FindNavigatorRoutable`.
- **An engine's background work is in `BackgroundWork/`**: `RuntimeEngineBackgroundWork` and what it holds —
  `Indexing/`, `FindCorpus/`, `CrossReferencePreparation/`, `ManualLoading/` — each with its state and
  results. A feature that reads them (Find, the Report, the toolbar's activity) does not hold their files.
- **RuntimeViewerAppUI mirrors RuntimeViewerAppCore.** A file that extends, draws or adapts an AppCore type
  goes in the directory of the same name as that type's: `RuntimeObject/RuntimeObjectIcon+Image.swift` beside
  AppCore's `RuntimeObject/RuntimeObjectIcon.swift`, `Content/ContentInterface+Theme.swift` beside
  `Content/ContentInterface.swift`. What only AppUI has gets a directory of its own (`Theme/`,
  `Resources/`) or goes with its one user (`NSColor+Xcode.swift`, the Find results'
  text colours, in `Find/Results/`).
- **A file is named after its main type.** Small helper types may stay beside it; a file whose name names no
  type in it, or that holds unrelated things, is split.

The test targets do not follow this yet: `RuntimeViewerAppCoreTests` and `RuntimeViewerAppUITests` are flat.

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
