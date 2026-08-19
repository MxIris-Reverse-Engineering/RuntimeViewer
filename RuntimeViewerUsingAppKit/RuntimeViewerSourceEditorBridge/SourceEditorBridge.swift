import AppKit
import SourceEditor
import SourceModelSupport

/// The only code in the project that references `SourceEditor`. It lives in a loadable
/// bundle so that the app itself carries no link-time dependency on Xcode's frameworks —
/// see `SourceEditorBridging` for why that separation is load-bearing.
@objc(RuntimeViewerSourceEditorBridge)
final class SourceEditorBridge: NSObject, SourceEditorBridging {
    private let sourceEditorView = SourceEditorView(frame: .zero)

    private let commandClickNavigator = CommandClickNavigator()

    private let semanticNodeTypeAdjuster = SemanticNodeTypeAdjuster()

    /// A gutter has to exist before there are any line numbers to show — the view ships
    /// without one — and it also draws the active-line emphasis, so it stays installed
    /// whether or not the numbers are wanted.
    private let gutter = SourceEditorGutter()

    /// What `applyDisplayOptions` last put into effect, so a settings change that moves one
    /// toggle does not re-run the other four. That is not just tidiness: `installMinimap()`
    /// and its siblings register margin accessories and event consumers unconditionally, so
    /// calling one twice installs the same overlay twice.
    ///
    /// The initial value must describe the view as `init` leaves it, not what a fresh
    /// `SourceEditorView` looks like — the gutter below turns line numbers on.
    private var appliedDisplayOptions = DisplayOptions(
        showsLineNumbers: true,
        showsFoldingRibbon: false,
        showsStickyHeaders: false,
        showsMinimap: false,
        showsScopeGuides: false,
        showsInvisibles: false,
        showsMarkSeparators: false
    )

    private struct DisplayOptions: Equatable {
        var showsLineNumbers: Bool
        var showsFoldingRibbon: Bool
        var showsStickyHeaders: Bool
        var showsMinimap: Bool
        var showsScopeGuides: Bool
        var showsInvisibles: Bool
        var showsMarkSeparators: Bool
    }

    weak var navigationDelegate: SourceEditorBridgingNavigationDelegate?

    var editorView: NSView { sourceEditorView }

    override init() {
        super.init()

        SourceModelDeclarationShortCircuitOverride.install()

        // Defaults to true, in which case the view takes ⌘-click as a multi-cursor
        // gesture and consumes it before any event consumer is offered the event.
        sourceEditorView.enableCmdClickMultiCursor = false
        sourceEditorView.isEditingEnabled = false

        gutter.enableLineNumbers()
        gutter.emphasizeActiveLines = true
        sourceEditorView.gutter = gutter

        commandClickNavigator.bridge = self
        sourceEditorView.addEventConsumer(commandClickNavigator)

        // Held weakly by the view, and the view is owned by this object, so this does not
        // retain-cycle and does not need clearing.
        sourceEditorView.contextualMenuItemProvider = self
    }

    func setSource(
        _ source: String,
        languageIdentifier: String,
        semanticRanges: [NSValue],
        semanticNodeTypeNames: [String]
    ) {
        let language: SourceEditorLanguage? =
            switch languageIdentifier {
            case "swift": SourceModelEditorLanguage.swift
            case "objc": SourceModelEditorLanguage.objc
            default: nil
            }

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
        (dataSource.languageService as? SourceModelLanguageService)?.nodeTypeAdjuster = semanticNodeTypeAdjuster
        sourceEditorView.dataSource = dataSource
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
    /// it directly but has no exported symbol to link against.
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
        showsMarkSeparators: Bool
    ) {
        let options = DisplayOptions(
            showsLineNumbers: showsLineNumbers,
            showsFoldingRibbon: showsFoldingRibbon,
            showsStickyHeaders: showsStickyHeaders,
            showsMinimap: showsMinimap,
            showsScopeGuides: showsScopeGuides,
            showsInvisibles: showsInvisibles,
            showsMarkSeparators: showsMarkSeparators
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
        }

        if options.showsFoldingRibbon != previousOptions.showsFoldingRibbon {
            if options.showsFoldingRibbon {
                sourceEditorView.installFoldingRibbon()
            } else {
                sourceEditorView.uninstallFoldingRibbon()
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

    func scrollToCharacterIndex(_ characterIndex: Int) {
        // TODO: needs SourceEditorView's scroll-to-position API reconstructed; the display
        // path works without it, so it is left unimplemented rather than half-guessed.
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
