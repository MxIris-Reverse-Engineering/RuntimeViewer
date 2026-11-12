// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
internal import SourceEditor
internal import SourceModelSupport

/// Drives the reconstructed `SourceEditor` frameworks, which this framework links directly. The app
/// gets one from `SourceEditorBridgeFactory` and talks to it through `SourceEditorBridging`, both of
/// which compile in every build; this class exists only where the frameworks are available (the
/// condition at the top).
@objc(RuntimeViewerSourceEditorBridge)
final class SourceEditorBridge: NSObject, SourceEditorBridging {
    private let sourceEditorView = SourceEditorView(frame: .zero)

    private let commandClickNavigator = CommandClickNavigator()

    private let semanticNodeTypeAdjuster = SemanticNodeTypeAdjuster()

    /// Draws the generated comments as tags and collapses their outlines. Lazy only because it
    /// needs the view; it is created and registered in `init`.
    private lazy var commentDecorationController = CommentDecorationController(sourceEditorView: sourceEditorView)

    /// A gutter has to exist before there are any line numbers to show — the view ships
    /// without one — and it also draws the active-line emphasis, so it stays installed
    /// whether or not the numbers are wanted.
    private let gutter = SourceEditorGutter()

    /// Answers the editor's question of where else the identifier under the insertion point
    /// appears. Every new language service gets it as its host, which holds it weakly.
    private let symbolOccurrenceProvider = SymbolOccurrenceProvider()

    /// What was folded in each interface this view has shown, and how far down it was
    /// scrolled. See `setSource`, which has to unfold before every swap and would otherwise lose
    /// both for good.
    private var readingStates = ReadingStateCache()

    /// Identifies the text currently in the view, so its reading state can be filed under the
    /// right key when the next one arrives. Nil until the first `setSource`.
    private var displayedSourceKey: ReadingStateCache.Key?

    /// The theme and line number font `applyTheme` last put into effect, which an inline expansion
    /// shown afterwards starts with. Nil until the first `applyTheme`.
    private var appliedTheme: SourceEditorTheme?
    private var appliedLineNumberFont: NSFont?

    /// How long the insertion point rests on an identifier before its other occurrences are
    /// highlighted. The framework leaves the highlight off until it is given a delay; this one is
    /// ours, chosen to come after a click settles without feeling slow, not taken from Xcode.
    private static let symbolOccurrenceHighlightDelay: Double = 0.25

    /// What `applyDisplayOptions` last put into effect, so a settings change that moves one
    /// toggle does not re-run the other four. That is not just tidiness: `installMinimap()`
    /// and its siblings register margin accessories and event consumers unconditionally, so
    /// calling one twice installs the same overlay twice.
    ///
    /// The initial value must describe the view as `init` leaves it, not what a fresh
    /// `SourceEditorView` looks like — the gutter below turns line numbers on, and `init` hides
    /// the caret.
    private var appliedDisplayOptions = DisplayOptions(
        showsLineNumbers: true,
        showsFoldingRibbon: false,
        showsStickyHeaders: false,
        showsMinimap: false,
        showsScopeGuides: false,
        showsInvisibles: false,
        showsMarkSeparators: false,
        showsInsertionPoint: false
    )

    private struct DisplayOptions: Equatable {
        var showsLineNumbers: Bool
        var showsFoldingRibbon: Bool
        var showsStickyHeaders: Bool
        var showsMinimap: Bool
        var showsScopeGuides: Bool
        var showsInvisibles: Bool
        var showsMarkSeparators: Bool
        var showsInsertionPoint: Bool
    }

    weak var navigationDelegate: SourceEditorBridgingNavigationDelegate?

    weak var minimapLandmarkIconProvider: SourceEditorBridgingMinimapLandmarkIconProvider?

    var editorView: NSView { sourceEditorView }

    /// One of the `.xccolortheme` files the framework ships in its own resources, such as
    /// `Default (Dark)`.
    static func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        guard let themeURL = Bundle(for: SourceEditorView.self).url(forResource: themeName, withExtension: "xccolortheme") else {
            return nil
        }
        return NSDictionary(contentsOf: themeURL)
    }

    override init() {
        super.init()

        SourceModelDeclarationShortCircuitOverride.install()

        // Defaults to true, in which case the view takes ⌘-click as a multi-cursor
        // gesture and consumes it before any event consumer is offered the event.
        sourceEditorView.enableCmdClickMultiCursor = false
        sourceEditorView.isEditingEnabled = false
        // An interface cannot be typed into, so a blinking caret only suggests that it can. With
        // editing disabled this stops the blink and leaves every cursor layer transparent; a
        // selection is still drawn and copied (`SourceEditorSelectionDisplay.update()`).
        // Settings › Editor › Insertion Point turns the caret back on (`applyDisplayOptions`).
        sourceEditorView.hideCursorWhenEditingDisabled = true

        // Set once and left alone: the framework never writes it on this scroll view — its only
        // `setAutohidesScrollers:` call belongs to the Go To list — and the scroller-style
        // observer `installScrollView()` registers only recomputes an inset.
//        sourceEditorView.scrollView.autohidesScrollers = true

        gutter.enableLineNumbers()
        gutter.emphasizeActiveLines = true
        sourceEditorView.gutter = gutter

        commandClickNavigator.bridge = self
        sourceEditorView.addEventConsumer(commandClickNavigator)

        // Registered once and kept: with no decorations loaded every answer it gives is empty.
        // `addLayoutOverrideProvider` files a provider under each protocol it conforms to.
        sourceEditorView.layoutManager.addLayoutOverrideProvider(commentDecorationController)
        sourceEditorView.layoutManager.addLayoutVisualization(commentDecorationController)
        sourceEditorView.addEventConsumer(commentDecorationController)
        // Cursor rects are the view's, not the layout manager's.
        sourceEditorView.addCursorRectOverrideProvider(commentDecorationController)

        // Held weakly by the view, and the view is owned by this object, so this does not
        // retain-cycle and does not need clearing.
        sourceEditorView.contextualMenuItemProvider = self

        // Registered here, unconditionally, and not once the app supplies its provider: the
        // minimap draws no hover label at all — not merely no icon — while it has nobody to ask
        // for the icon. See the conformance at the end of this file. Held weakly by the view.
        sourceEditorView.setMinimapLandmarkIconProvider(self)

        // The highlight of the other occurrences of a clicked identifier. The view draws it
        // (`SelectedSymbolHighlight`) once it has a delay — nil, the default, leaves it off — and
        // the provider, installed on each language service in `setSource`, finds them.
        symbolOccurrenceProvider.sourceEditorView = sourceEditorView
        sourceEditorView.selectedSymbolHighlightDelay = Self.symbolOccurrenceHighlightDelay
    }

    func setSource(
        _ source: String,
        languageIdentifier: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String],
        commentDecorations: SourceEditorBridgingCommentDecorations?,
        restoresScrollPosition: Bool
    ) {
        let language = Self.language(forIdentifier: languageIdentifier)

        semanticNodeTypeAdjuster.load(
            semanticRanges: semanticRanges.map(\.rangeValue),
            nodeTypeNames: semanticNodeTypeNames
        )

        let dataSource = SourceEditorDataSource(
            usingMutableString: NSMutableString(string: source),
            language: language,
            formattingOptions: SourceEditorFormattingOptions()
        )
        // Reading `languageService` is what creates it — it is lazy — so this both brings the
        // service up and installs the adjuster before anything asks the data source to parse.
        //
        // The adjuster goes in first: the host's setter also re-installs the adjuster, falling back
        // to the host when the service has none of its own, and this host is not one.
        if let languageService = dataSource.languageService as? SourceModelLanguageService {
            languageService.nodeTypeAdjuster = semanticNodeTypeAdjuster
            languageService.hostExtension = symbolOccurrenceProvider
        }
        symbolOccurrenceProvider.load(source: source)

        // **Before the assignment, never after.** Folds belong to the view, not to the data
        // source: `SourceEditorView.dataSource`'s setter reaches the folding controller only to
        // run its own `dataSource` didSet, which rebuilds the delimiter data and leaves the fold
        // list untouched. Xcode never notices because it gives every document its own editor;
        // this bridge reuses one view for every interface it shows, so a fold made in one
        // survives into the next.
        //
        // The layout manager then asks `FoldedRegionDisplay` for that line's visible column
        // ranges, which builds `foldEnd.column ..< lineLength` from the stale fold and the new
        // line — and traps on the reversed bounds as soon as the new text is shorter. It is a
        // hard crash, not a glitch, and it lands inside the sidebar click's own event tracking.
        //
        // Unfolding here is the only ordering that works: it runs against the data source the
        // folds were made in, so the relayout it triggers is self-consistent. Doing it after the
        // assignment would take the same trap on the way through.
        //
        // Saving first is what keeps that from also throwing the reader's folds away: leaving a
        // class and coming back would otherwise arrive fully expanded every time. The scroll
        // position is taken in the same breath, while the folds it was measured with are still
        // in place; the new data source would otherwise start at the top.
        if let displayedSourceKey {
            readingStates.store(
                ReadingStateCache.ReadingState(
                    foldState: sourceEditorView.foldingController.stateDictionaryForSaving,
                    scrollPosition: sourceEditorView.scrollStateForStateRestoration()
                ),
                for: displayedSourceKey
            )
        }
        // The inline expansions go first: a gap hangs under a line of the data source it was
        // inserted into, and keeps that line's identifier, which the new data source does not have.
        sourceEditorView.editorGapController.removeAllGapItems()
        // **The old decorations go before the unfold**, which lays the old text out again: they
        // are columns of the text they came with, and a column past the end of a line is a
        // `fatalError` in the framework. The new ones come in only once their text is in place.
        commentDecorationController.clear()
        sourceEditorView.foldingController.unfoldAll(animate: false)

        sourceEditorView.dataSource = dataSource
        commentDecorationController.load(commentDecorations, source: source)

        // Straight after the assignment, with no layout in between: `restore(from:)` reads line
        // and column numbers, not the parse, so it does not need one (measured). It also guards
        // itself — a state whose `documentLength` disagrees with the new text is discarded
        // whole, and a position outside that text is dropped rather than folded — but the key
        // is what makes it *correct*, not just safe.
        //
        // A source shown for the first time starts with its decorated rows collapsed instead.
        let sourceKey = ReadingStateCache.Key(source: source, isDecorated: commentDecorations != nil)
        displayedSourceKey = sourceKey
        let savedState = readingStates.state(for: sourceKey)
        if let foldState = savedState?.foldState as? [AnyHashable: Any] {
            sourceEditorView.foldingController.restore(from: foldState)
        } else {
            commentDecorationController.collapseRowsThatStartCollapsed()
        }

        // After the folds, which the saved line was counted against. A text shown before goes
        // back to where it was left, any other to the top: the view keeps the clip view's origin
        // across a data source swap, so a new interface would otherwise open as far down as the
        // last one was scrolled. The top is the position `currentScrollState()` reports for a
        // view with nothing laid out.
        //
        // Deferred, the way the framework restores a document's position itself: the view holds
        // the position and scrolls to it when the next layout finishes
        // (`layoutManager(_:didFinishLayoutInContentView:)`), since nothing of the new text is
        // laid out yet. That wait is also why a reveal that follows asks for neither — it would
        // land first and be scrolled away.
        guard restoresScrollPosition else { return }
        let topScrollPosition = (line: 0, offset: -sourceEditorView.contentView.layoutMargins.top)
        sourceEditorView.applyScrollState(savedState?.scrollPosition ?? topScrollPosition, defer: true)
    }

    func applyCommentTagAppearance(_ appearance: SourceEditorBridgingCommentTagAppearance) {
        commentDecorationController.applyTagAppearance(CommentDecorationController.TagAppearance(appearance))
    }

    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: NSFont) {
        guard let themeDictionary = dictionary as? [String: AnyHashable] else { return }
        let theme = SourceEditorTheme(name: name, dictionary: themeDictionary, fontSizeModifier: fontSizeModifier)

        // Before the theme is assigned, not after: writing the margin does not itself invalidate
        // the laid-out lines, and the theme assignment is what flushes it. See the method below.
        applyTextLeadingMargin(forPointSize: lineNumberFont.pointSize)

        sourceEditorView.colorTheme = theme
        sourceEditorView.fontTheme = theme
        applyLineNumberFont(lineNumberFont)
        appliedTheme = theme
        appliedLineNumberFont = lineNumberFont
        for expansionView in InlineExpansionView.views(in: sourceEditorView) {
            expansionView.apply(theme, lineNumberFont: lineNumberFont)
        }

        // `showInvisibles()` copies the colour out of whatever theme was current when it ran,
        // so a theme applied afterwards leaves the invisible glyphs in the old one. Re-running
        // it is the only way to refresh them; it is a no-op when they are off.
        if appliedDisplayOptions.showsInvisibles {
            sourceEditorView.showInvisibles()
        }
    }

    /// **Without this the gutter is empty and 6pt wide, which reads as "line numbers do not
    /// work" rather than as a missing font.** The gutter sizes each number by laying the digits
    /// out in a text layer using the font stored on its content view, and that font starts nil
    /// — `enableLineNumbers()` only flips a flag. Every layer then measures 0×0, the margin
    /// collapses to the divider, and nothing is drawn. No theme key covers it either: the
    /// `.xccolortheme` format has no gutter entry at all.
    private func applyLineNumberFont(_ lineNumberFont: NSFont) {
        guard gutter.lineNumberFont != lineNumberFont else { return }
        gutter.lineNumberFont = lineNumberFont

        // The setter drops the cached digit sizes but does not schedule a redisplay; the
        // private method that does is only reachable through these two, which write the flag
        // and then refresh. Calling it while numbers are off would turn them back on.
        if appliedDisplayOptions.showsLineNumbers {
            gutter.enableLineNumbers()
        }
    }

    /// Separates the text from the folding ribbon, which otherwise sits flush against it.
    ///
    /// The ribbon's own width is `leadingInset + 7`, and on macOS 26 that leading inset — 4pt —
    /// goes on the side facing the line numbers, leaving nothing on the side facing the text.
    /// Xcode used to make up the difference with `SourceEditorContentView.additionalLeftPadding`,
    /// which `updateAdditionalLeftPadding()` filled with `round(pointSize / 2)`; as of macOS 26
    /// that method leaves it at zero unless a gutter annotation is present, and this view has
    /// none. `contentMargins` is the same offset by a different name — the text's origin is
    /// `accessoryMargins.left + contentMargins.left + additionalLeftPadding` — with the
    /// advantage that nothing in the framework writes it.
    ///
    /// Keeping Xcode's own formula means the gap tracks the font size rather than being a
    /// constant that looks right at one size only.
    ///
    /// **Assigning this does not schedule a relayout.** The laid-out lines keep their old
    /// origins until something else invalidates them — a `setSource`, or the theme assignment
    /// this is called just ahead of. `SourceEditorLayoutManager.invalidateAllLayout()` would do
    /// it directly; it is exported (26.6 and 27.2 alike) and the comment decorations call it,
    /// but the theme assignment already covers this path.
    private func applyTextLeadingMargin(forPointSize pointSize: CGFloat) {
        let leadingMargin = (pointSize * 0.5).rounded()
        guard sourceEditorView.contentView.contentMargins.left != leadingMargin else { return }
        sourceEditorView.contentView.contentMargins.left = leadingMargin
    }

    func applyBackgroundColor(_ backgroundColor: NSColor) {
        // Set alongside the theme's own background key rather than instead of it: the theme
        // drives what the editor paints behind text, this drives the view itself, and a
        // mismatch shows up as a differently-coloured band past the end of the document.
        sourceEditorView.backgroundColor = backgroundColor
    }

    func applyDisplayOptions(
        showsLineNumbers: Bool,
        showsFoldingRibbon: Bool,
        showsStickyHeaders: Bool,
        showsMinimap: Bool,
        showsScopeGuides: Bool,
        showsInvisibles: Bool,
        showsMarkSeparators: Bool,
        showsInsertionPoint: Bool
    ) {
        let options = DisplayOptions(
            showsLineNumbers: showsLineNumbers,
            showsFoldingRibbon: showsFoldingRibbon,
            showsStickyHeaders: showsStickyHeaders,
            showsMinimap: showsMinimap,
            showsScopeGuides: showsScopeGuides,
            showsInvisibles: showsInvisibles,
            showsMarkSeparators: showsMarkSeparators,
            showsInsertionPoint: showsInsertionPoint
        )
        guard options != appliedDisplayOptions else { return }
        let previousOptions = appliedDisplayOptions
        appliedDisplayOptions = options

        if options.showsLineNumbers != previousOptions.showsLineNumbers {
            if options.showsLineNumbers {
                gutter.enableLineNumbers()
            } else {
                gutter.disableLineNumbers()
            }
            for expansionView in InlineExpansionView.views(in: sourceEditorView) {
                expansionView.setShowsLineNumbers(options.showsLineNumbers)
            }
        }

        if options.showsFoldingRibbon != previousOptions.showsFoldingRibbon {
            if options.showsFoldingRibbon {
                sourceEditorView.installFoldingRibbon()
            } else {
                sourceEditorView.uninstallFoldingRibbon()
            }
            // The ribbon moves where the text starts, which every expansion lines up with.
            for expansionView in InlineExpansionView.views(in: sourceEditorView) {
                expansionView.needsLayout = true
            }
        }

        if options.showsStickyHeaders != previousOptions.showsStickyHeaders {
            if options.showsStickyHeaders {
                sourceEditorView.installStickyHeaders()
            } else {
                sourceEditorView.uninstallStickyHeaders()
            }
        }

        if options.showsMinimap != previousOptions.showsMinimap {
            if options.showsMinimap {
                sourceEditorView.installMinimap()
            } else {
                sourceEditorView.uninstallMinimap()
            }
        }

        // The switch's didSet asks for a layout, and the selection display decides after every
        // layout whether to blink the caret or hide it, so a change shows at once without a
        // selection change. Written only on a change, because every write asks for that layout.
        if options.showsInsertionPoint != previousOptions.showsInsertionPoint {
            sourceEditorView.hideCursorWhenEditingDisabled = !options.showsInsertionPoint
        }

        if options.showsInvisibles != previousOptions.showsInvisibles {
            if options.showsInvisibles {
                sourceEditorView.showInvisibles()
            } else {
                sourceEditorView.hideInvisibles()
            }
        }

        // Idempotent, like the scope guides below — both write the same flag on the same
        // lazily-created controller — so this needs no state tracking either.
        if options.showsMarkSeparators {
            sourceEditorView.showMarkSeparators()
        } else {
            sourceEditorView.hideMarkSeparators()
        }

        // Called unconditionally, unlike the pairs above: both sides read the flag they are
        // about to write and do nothing when it did not change, so this is the one option
        // whose real state does not have to be tracked to stay correct.
        if options.showsScopeGuides {
            sourceEditorView.showScopeGuides()
        } else {
            sourceEditorView.hideScopeGuides()
        }
    }

    func applyTopContentInset(_ topInset: CGFloat) {
        // **`default`, not `additional`.** The scroll view's insets are the sum of the two, but
        // `additional` is the find panel's own channel: presenting it writes the panel's height
        // straight into `additional.top`, which silently threw away the toolbar inset that used
        // to live there and left the panel itself flush against the window's top edge.
        guard sourceEditorView.defaultScrollViewContentInsets.top != topInset else { return }
        sourceEditorView.defaultScrollViewContentInsets.top = topInset
    }

    func revealCharacterRange(_ characterRange: NSRange) {
        let dataSource = sourceEditorView.dataSource
        // `positionFromInternalCharOffset` is the inverse of the `characterRangeForLineRange`
        // arithmetic in `characterIndex(of:in:)`: both live in the data source's internal offset
        // space, which is the UTF-16 offset of the string we supplied. A hint of 0 is safe
        // (a negative one traps); the lookup falls back to a binary search when the hint misses.
        let lowerBound = dataSource.positionFromInternalCharOffset(max(0, characterRange.location), lineHint: 0)
        let upperBound = dataSource.positionFromInternalCharOffset(max(0, NSMaxRange(characterRange)), lineHint: lowerBound.line)
        let range = lowerBound ..< max(lowerBound, upperBound)
        // The same two calls Xcode's own editor makes for a Find result: select with a scroll
        // placement, then pop the callout. `.center`, not Xcode's `.optimal`, because the hit
        // is usually far from the previous scroll position and "optimal" leaves it at an edge.
        sourceEditorView.selectTextRange(range, scrollPlacement: .center, alwaysScroll: true)
        sourceEditorView.showCallout(for: range)
    }

    func showFindInterface(query: String, pattern: SourceEditorBridgingFindPattern, isCaseSensitive: Bool) {
        let window = sourceEditorView.window
        let previousFirstResponder = window?.firstResponder

        // The query first, then the bar. With the bar closed, the query's observer only writes
        // the find pasteboard, and opening the bar runs the query with the matches drawn and
        // nothing selected (`displayTextFindableControl(mode:)`). With the bar already open, the
        // observer runs the query at once, but hides the matches while the editor is not the
        // first responder; opening the bar again draws them, and does nothing else to a bar that
        // is already there.
        sourceEditorView.findQuery = TextFindQuery(
            find: query,
            caseSensitive: isCaseSensitive,
            pattern: Self.textFindPattern(for: pattern)
        )
        sourceEditorView.perform(NSTextFinder.Action.showFindInterface)

        // Presenting the bar makes it the first responder (`present(_:)`, 26.6.3; 0x3DD7F0), as
        // it should be for ⌘F. Here the reader is stepping through the Find navigator's results
        // with the arrow keys, which taking the focus would stop.
        if let window, let previousFirstResponder, window.firstResponder !== previousFirstResponder {
            window.makeFirstResponder(previousFirstResponder)
        }
    }

    private static func textFindPattern(for pattern: SourceEditorBridgingFindPattern) -> TextFindPattern {
        switch pattern {
        case .contains: .contains
        case .matchesWord: .matchesWord
        case .startsWith: .startsWith
        case .endsWith: .endsWith
        case .regularExpression: .regularExpression
        }
    }

    fileprivate func reportCommandClick(at position: SourceEditorPosition) {
        guard let navigationDelegate, let characterRange = characterRange(ofTokenAt: position) else { return }
        navigationDelegate.sourceEditorBridge(self, didCommandClickTokenIn: characterRange)
    }

    /// The UTF-16 range of the token at `position`, in the source last passed to `setSource`.
    private func characterRange(ofTokenAt position: SourceEditorPosition) -> NSRange? {
        let dataSource = sourceEditorView.dataSource
        guard let (_, tokenRange) = dataSource.tokenRangeAtPosition(position) else { return nil }

        let lowerBound = characterIndex(of: tokenRange.lowerBound, in: dataSource)
        let upperBound = characterIndex(of: tokenRange.upperBound, in: dataSource)
        guard upperBound > lowerBound else { return nil }
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }

    /// A `SourceEditorPosition` is a line/column pair; the app indexes the same text by
    /// UTF-16 offset, which is what `NSAttributedString` uses.
    private func characterIndex(of position: SourceEditorPosition, in dataSource: SourceEditorDataSource) -> Int {
        let lineRange = dataSource.characterRangeForLineRange(NSRange(location: position.line, length: 1))
        return lineRange.location + position.col
    }
}

// MARK: - Inline Expansions

/// Names an inline expansion's gap, so that it cannot be taken for a gap anything else inserts.
private struct InlineExpansionGapIdentifier: Hashable {
    let identifier: String
}

/// An inline expansion is gaps of the editor's own `editorGapController` — the mechanism Xcode
/// shows an expanded macro with, which is SourceEditor's, not Xcode's — each holding an
/// `InlineExpansionView`. The framework draws a gap's tint, border and dismiss button, folds it
/// open, and lists it in the accessibility rotor of expanded macros. Every gap of one expansion
/// carries the same identifier, and the dismiss button removes the gaps of its identifier, so any
/// of them closes them all; a Command-click closes every expansion.
extension SourceEditorBridge {
    func showInlineExpansion(
        _ parts: [SourceEditorBridgingInlineExpansionPart],
        languageIdentifier: String,
        title: String,
        identifier: String
    ) {
        let gapIdentifier = InlineExpansionGapIdentifier(identifier: identifier)
        let gapController = sourceEditorView.editorGapController
        guard !parts.isEmpty, !gapController.hasGapItemWithIdentifier(gapIdentifier) else { return }

        let dataSource = sourceEditorView.dataSource
        let language = Self.language(forIdentifier: languageIdentifier)
        for part in parts {
            // The same conversion `revealCharacterRange(_:)` makes.
            let lowerBound = dataSource.positionFromInternalCharOffset(max(0, part.anchorRange.location), lineHint: 0)
            let upperBound = dataSource.positionFromInternalCharOffset(max(0, NSMaxRange(part.anchorRange)), lineHint: lowerBound.line)
            let range = lowerBound ..< max(lowerBound, upperBound)
            let position: SourceEditorGapItem.Position = switch part.placement {
            case .belowLine: .belowLine
            case .aboveLine: .aboveLine
            }

            let expansionView = InlineExpansionView(
                source: part.source,
                language: language,
                semanticRanges: part.semanticRanges.map(\.rangeValue),
                semanticNodeTypeNames: part.semanticNodeTypeNames,
                title: title,
                indent: Self.inlineExpansionIndent(for: range, position: position, in: dataSource),
                anchorLine: range.upperBound.line,
                hostEditorView: sourceEditorView
            )
            expansionView.setShowsLineNumbers(appliedDisplayOptions.showsLineNumbers)
            if let appliedTheme, let appliedLineNumberFont {
                expansionView.apply(appliedTheme, lineNumberFont: appliedLineNumberFont)
            }
            // The arguments Xcode 26.6 gives an expanded macro's gap in
            // `MacroManager.showInGap(macroReplacement:in:workspace:)` (IDESourceEditor 0x1816D0): a
            // point above and below, a 5 % tint and a 15 % border, no highlight of the range. The
            // controller hangs the gap at the line of the range's end.
            gapController.insertGapItem(SourceEditorGapItem(
                identifier: gapIdentifier,
                range: range,
                contentView: expansionView,
                position: position,
                insets: NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0),
                backgroundColor: (light: NSColor.black.withAlphaComponent(0.05), dark: NSColor.white.withAlphaComponent(0.05)),
                borderColor: (light: NSColor.black.withAlphaComponent(0.15), dark: NSColor.white.withAlphaComponent(0.15)),
                highlightRange: false
            ))
        }
    }

    func hideInlineExpansion(identifier: String) {
        sourceEditorView.editorGapController.removeGapItemsWithIdentifier(InlineExpansionGapIdentifier(identifier: identifier))
    }

    func isInlineExpansionShown(identifier: String) -> Bool {
        sourceEditorView.editorGapController.hasGapItemWithIdentifier(InlineExpansionGapIdentifier(identifier: identifier))
    }

    /// The SourceModel language a `languageIdentifier` of `setSource` names; nil leaves the text
    /// uncoloured by the framework's own parse.
    static func language(forIdentifier languageIdentifier: String) -> (any SourceEditorLanguage)? {
        switch languageIdentifier {
        case "swift": SourceModelEditorLanguage.swift
        case "objc": SourceModelEditorLanguage.objc
        default: nil
        }
    }

    /// How far Xcode indents an expanded macro's editor, in columns
    /// (`MacroManager.showInGap`, IDESourceEditor 26.6 0x1816D0): the leading whitespace of the line
    /// the range starts on, tabs expanded, plus one indent width when the gap opens above a line
    /// starting with `}` — a body's end, which the expansion belongs inside — below a line ending
    /// with `{`, or when the range ends before the end of its line.
    static func inlineExpansionIndent(
        for range: Range<SourceEditorPosition>,
        position: SourceEditorGapItem.Position,
        in dataSource: SourceEditorDataSource
    ) -> Int {
        let lineIndent = dataSource.leadingWhitespaceWidthForLine(range.lowerBound.line, expandTabs: true)
        let lastLine = range.upperBound.line
        let lastLineContent = dataSource.lineContentForLine(lastLine)
        let opensAboveBodyEnd = position == .aboveLine
            && lastLineContent.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("}")
        let opensBelowBodyStart = position == .belowLine && lastLineContent.hasSuffix("{")
        let endsInsideItsLine = range.upperBound.col < dataSource.lineContentLengthForLine(lastLine)
        guard opensAboveBodyEnd || opensBelowBodyStart || endsInsideItsLine else { return lineIndent }
        return lineIndent + dataSource.formattingOptions.indentWidth
    }
}

// MARK: - Contextual Menu

/// The editor builds its contextual menu itself — `defaultMenu` is Cut/Copy/Paste, freshly
/// constructed per click, plus whatever the spell checker adds — and offers this one hook to
/// put something else in it.
///
/// **The hook is handed the menu and nothing else**, no event and no position, so where the
/// click landed has to come from somewhere. `NSApp.currentEvent` is that somewhere: the whole
/// path from `rightMouseDown` to `popUpContextMenu(_:withEvent:forView:)` runs inside the
/// handling of one event, and it is the same event the framework itself measures the click by.
/// Reading it here beats recording the position from an event consumer, which would only be
/// correct while this bridge's consumer keeps running ahead of the framework's own
/// `ContextualMenuEventConsumer` — an ordering nothing enforces.
extension SourceEditorBridge: SourceEditorViewContextualMenuItemProvider {
    func setupContextMenu(for menu: NSMenu) {
        removeCutItem(from: menu)

        guard let navigationDelegate,
              let characterRange = characterRangeOfTokenUnderPointer()
        else { return }

        let items = navigationDelegate.sourceEditorBridge(self, contextualMenuItemsForTokenIn: characterRange)
        guard !items.isEmpty else { return }

        for (index, item) in items.enumerated() {
            menu.insertItem(item, at: index)
        }
        menu.insertItem(.separator(), at: items.count)
    }

    /// **Cut stays enabled in a read-only editor, and pressing it behaves like Copy.**
    ///
    /// `validateUserInterfaceItem(_:)` gates Paste on `isEditingEnabled`, but gates Cut and
    /// Copy only on the selection being non-empty — and right-clicking a token selects it, so
    /// Cut is always live. Pressing it runs `copy:` and then sends itself `delete:`, which
    /// `SourceEditorView` does not implement: `delete:` belongs to its
    /// `SourceEditorViewMissingKeyBindings` protocol, an `@objc` protocol the framework
    /// declares and leaves entirely to its host, so `NSResponder.forwardInvocation(_:)` walks
    /// it up a responder chain where nothing handles it and it is dropped.
    ///
    /// Nothing breaks, then — but a Cut that silently means Copy is worse than no Cut, and
    /// this pane never edits anything.
    private func removeCutItem(from menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.action == #selector(NSText.cut(_:)) }) else { return }
        menu.removeItem(at: index)
    }

    private func characterRangeOfTokenUnderPointer() -> NSRange? {
        guard let event = NSApp.currentEvent else { return nil }
        let viewPoint = sourceEditorView.convert(event.locationInWindow, from: nil)
        guard let position = sourceEditorView.positionAtPoint(viewPoint) else { return nil }
        return characterRange(ofTokenAt: position)
    }
}

// MARK: - Command Click

extension SourceEditorBridge {
    /// `SourceEditorView.mouseDown(with:)` offers each event to the registered consumers and
    /// otherwise falls through to its selection controller. That makes this — not the
    /// `codeNavigationHandler` property, which only the framework's own Vim command handlers
    /// ever read — the way to see a ⌘-click.
    fileprivate final class CommandClickNavigator: NSObject, SourceEditorViewEventConsumer {
        weak var bridge: SourceEditorBridge?

        var consumerPriority: SourceEditorEventConsumerPriority { .highest }

        func handleMouseEvent(_ event: NSEvent, in sourceEditorView: SourceEditorView) -> Bool {
            guard event.type == .leftMouseDown, event.modifierFlags.contains(.command) else { return false }

            let viewPoint = sourceEditorView.convert(event.locationInWindow, from: nil)
            guard let position = sourceEditorView.positionAtPoint(viewPoint) else {
                // Consumed regardless: a ⌘-click that misses a token must not fall through
                // and start a selection drag.
                return true
            }
            bridge?.reportCommandClick(at: position)
            return true
        }
    }
}

// MARK: - Minimap Landmark Icons

/// The framework builds a hover label's layers only when it has somewhere to ask for the icon:
/// `MinimapView.showExpandedLandmarks(_:mainLandmark:availableWidth:)` returns before creating
/// one when its weak `iconProvider` is nil. The accent-coloured scope highlight is drawn by an
/// earlier call and appears regardless, which is why a missing provider looks like "the frame
/// shows but no text" rather than like nothing happening. So the bridge always registers itself
/// and answers with whatever the app supplies, nil included — nil only costs the icon, and the
/// label then starts at its left edge instead of after the icon's square.
extension SourceEditorBridge: MinimapLandmarkIconProvider {
    /// The side of the square the framework lays the icon out in. It sizes the icon at the
    /// label's height minus 4pt (`showExpandedLandmarks`, 26.6 @ 0x1B75E8), and the label is
    /// 18pt tall — read off Xcode's own layer tree, where a hovered
    /// `MinimapExpandedLandmarkLayer` is 18pt and its `MinimapLandmarkLayer` child starts at
    /// x = 18, which is 2 + 14 + 2.
    private static let iconPointSize: CGFloat = 14

    func icon(for landmarkType: LandmarkType) -> CGImage? {
        guard let minimapLandmarkIconProvider,
              let image = minimapLandmarkIconProvider.sourceEditorBridge(
                  self,
                  minimapIconForLandmarkOfKind: Self.landmarkKind(for: landmarkType),
                  pointSize: Self.iconPointSize
              )
        else { return nil }
        return rasterize(image, pointSize: Self.iconPointSize)
    }

    /// The framework never draws the image itself — it assigns it as a layer's `contents` and
    /// copies the content layer's `contentsScale` over — so what it needs is a bitmap already at
    /// the screen's scale, and, for an image drawn by a handler, already resolved against the
    /// editor's appearance. Both are decided here rather than left to `NSImage`'s defaults.
    private func rasterize(_ image: NSImage, pointSize: CGFloat) -> CGImage? {
        let scale = sourceEditorView.window?.backingScaleFactor ?? 2
        let pixelLength = Int((pointSize * scale).rounded(.up))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelLength,
            pixelsHigh: pixelLength,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        // In points, so the context below draws at `scale` rather than one pixel per point.
        bitmap.size = NSSize(width: pointSize, height: pointSize)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        sourceEditorView.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: bitmap.size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        return bitmap.cgImage
    }

    /// Declaration and definition fold together — Xcode draws them alike, and this pane shows
    /// interfaces, where everything is a declaration anyway. `@unknown default` is required:
    /// the enum is resilient, and a case Xcode adds later must not stop the label.
    private static func landmarkKind(for landmarkType: LandmarkType) -> SourceEditorBridgingLandmarkKind {
        switch landmarkType {
        case .mark: .mark
        case .file: .file
        case .actorDef: .actor
        case .classDecl, .classDef: .class
        case .extensionDecl, .extensionDef: .extension
        case .protocolDecl, .protocolDef: .protocol
        case .methodDecl, .methodDef: .method
        case .functionDecl, .functionDef: .function
        case .propertyDecl, .propertyDef: .property
        case .enumDef: .enum
        case .structDef: .struct
        case .unionDef: .union
        case .typeDef: .typeAlias
        case .include: .include
        case .define: .define
        case .macro: .macro
        case .blockDirective, .rule, .entity, .attribute, .anchorTarget, .anchorLink,
             .key, .style, .heading, .probe, .process, .thread:
            .other
        @unknown default: .other
        }
    }
}

#endif
