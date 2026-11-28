// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them. iOS only: it drives the UIKit build
// of the frameworks, which the iOS pin (PinnedRelease-iOS.txt, the 26.6 line) carries.
#if os(iOS) && arch(arm64) && canImport(SourceEditor)

import UIKit
internal import SourceEditor
internal import SourceModelSupport

/// The iOS bridge: what `SourceEditorBridge` is on macOS, for the UIKit build of the frameworks.
///
/// That build has no folding, no gaps and no event consumers that receive a touch, so this one
/// shows a text with its semantic runs, the theme, line numbers, the minimap, mark separators, the
/// highlight of a tapped identifier's other occurrences and the system find navigator, and keeps the
/// reader's place — and nothing of the comment tags, inline expansions, line-end tags or ⌘-click the
/// macOS bridge adds (`SourceEditorBridging`).
@objc(RuntimeViewerUIKitSourceEditorBridge)
final class UIKitSourceEditorBridge: NSObject, SourceEditorBridging {
    private let sourceEditorView = ReadOnlySourceEditorView(frame: .zero)

    private let semanticNodeTypeAdjuster = SemanticNodeTypeAdjuster()

    /// A gutter has to exist before there are any line numbers to show — the view ships without
    /// one — and it also draws the active-line emphasis, so it stays installed whether or not the
    /// numbers are wanted.
    private let gutter = SourceEditorGutter()

    /// Answers the editor's question of where else the identifier under the insertion point
    /// appears. Every new language service gets it as its host, which holds it weakly.
    private let symbolOccurrenceProvider = SymbolOccurrenceProvider()

    /// The first visible line of each interface this view has shown.
    ///
    /// A line rather than a content offset: replacing the data source puts `contentOffset.y` back to
    /// zero and `contentSize` to zero (`willReplaceDataSource()` and `didReplaceDataSource()`,
    /// reconstruction 26.6.10), and the height is known again only once the lines are laid out, so an
    /// offset could not be put back before that, while `scrollToLine` grows the content to reach its
    /// line. It places the line a tenth of the view's height below the top, so a text comes back a
    /// few lines higher than it was left.
    private var readingStates = ReadingStateCache<Int>()

    /// Identifies the text currently in the view, so its reading state can be filed under the
    /// right key when the next one arrives. Nil until the first `setSource`.
    private var displayedSourceKey: ReadingStateCache<Int>.Key?

    /// The line `setSource` will scroll back to once the new text is laid out, nil for none.
    private var pendingFirstVisibleLine: Int?

    /// How long the insertion point rests on an identifier before its other occurrences are
    /// highlighted; the macOS bridge's value.
    private static let symbolOccurrenceHighlightDelay: Double = 0.25

    /// What `applyDisplayOptions` last put into effect, so a settings change that moves one toggle
    /// does not re-run the others: `installMinimap()` installs a second minimap when one is shown.
    /// The initial value describes the view as `init` leaves it.
    private var appliedDisplayOptions = DisplayOptions(
        showsLineNumbers: true,
        showsMinimap: false,
        showsMarkSeparators: false,
        showsInsertionPoint: false
    )

    /// The options of `applyDisplayOptions` this build can carry out.
    private struct DisplayOptions: Equatable {
        var showsLineNumbers: Bool
        var showsMinimap: Bool
        var showsMarkSeparators: Bool
        var showsInsertionPoint: Bool
    }

    weak var minimapLandmarkIconProvider: SourceEditorBridgingMinimapLandmarkIconProvider?

    var editorView: UIView { sourceEditorView }

    /// One of the `.xccolortheme` files the framework ships in its own resources, such as
    /// `Default (Dark)`; the UIKit build carries both defaults too.
    static func builtInThemeDictionary(named themeName: String) -> NSDictionary? {
        guard let themeURL = Bundle(for: SourceEditorView.self).url(forResource: themeName, withExtension: "xccolortheme") else {
            return nil
        }
        return NSDictionary(contentsOf: themeURL)
    }

    override init() {
        super.init()

        SourceModelDeclarationShortCircuitOverride.install()

        sourceEditorView.isEditingEnabled = false
        // As on macOS: a blinking caret in a text that cannot be typed into only suggests that it
        // can. Settings › Editor › Insertion Point turns it back on (`applyDisplayOptions`).
        sourceEditorView.hideCursorWhenEditingDisabled = true

        gutter.enableLineNumbers()
        gutter.emphasizeActiveLines = true
        sourceEditorView.gutter = gutter

        // Told when the lines are laid out, which is when a reading position can be put back.
        sourceEditorView.editorDelegate = self

        // Registered unconditionally, as on macOS: the minimap draws no hover label at all while it
        // has nobody to ask for the icon. Held weakly by the view.
        sourceEditorView.setMinimapLandmarkIconProvider(self)

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
        let language = SourceEditorBridgeLookup.language(forIdentifier: languageIdentifier)

        semanticNodeTypeAdjuster.load(
            semanticRanges: semanticRanges.map(\.rangeValue),
            nodeTypeNames: semanticNodeTypeNames
        )

        let dataSource = SourceEditorDataSource(
            usingMutableString: NSMutableString(string: source),
            language: language,
            formattingOptions: SourceEditorFormattingOptions()
        )
        // As on macOS: reading `languageService` creates it, and the adjuster goes in before the
        // host, whose setter re-installs the adjuster.
        if let languageService = dataSource.languageService as? SourceModelLanguageService {
            languageService.nodeTypeAdjuster = semanticNodeTypeAdjuster
            languageService.hostExtension = symbolOccurrenceProvider
        }
        symbolOccurrenceProvider.load(source: source)

        if let displayedSourceKey {
            readingStates.store(sourceEditorView.visibleLineRange.lowerBound, for: displayedSourceKey)
        }

        sourceEditorView.dataSource = dataSource

        let sourceKey = ReadingStateCache<Int>.Key(source: source, isDecorated: false)
        displayedSourceKey = sourceKey
        let savedFirstVisibleLine = readingStates.state(for: sourceKey)
        // Any other text starts at the top, where replacing the data source has already put the
        // view. A reveal is never asked for on iOS, but the contract is the macOS one: no restore
        // when the caller says so.
        pendingFirstVisibleLine = restoresScrollPosition ? savedFirstVisibleLine.flatMap { $0 > 0 ? $0 : nil } : nil
    }

    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int, lineNumberFont: UIFont) {
        guard let themeDictionary = dictionary as? [String: AnyHashable] else { return }
        let theme = SourceEditorTheme(name: name, dictionary: themeDictionary, fontSizeModifier: fontSizeModifier)

        // Separates the text from the line numbers, the macOS bridge's `round(pointSize / 2)`.
        // Written before the theme, whose assignment lays the lines out again.
        let leadingMargin = (lineNumberFont.pointSize * 0.5).rounded()
        if sourceEditorView.contentViewContentMargins.left != leadingMargin {
            sourceEditorView.contentViewContentMargins.left = leadingMargin
        }

        sourceEditorView.setTheme(theme)

        // The theme dictionary has no key for the gutter's font. The setter drops the cached digit
        // sizes without a redisplay, and enabling the numbers again is what redraws them (the
        // UIKit example App does the same after every theme change).
        gutter.lineNumberFont = lineNumberFont
        if appliedDisplayOptions.showsLineNumbers {
            gutter.enableLineNumbers()
        }
    }

    func applyBackgroundColor(_ backgroundColor: UIColor) {
        // Alongside the theme's own background key: the theme paints behind the text, this the
        // view itself, past the end of the document.
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
            showsMinimap: showsMinimap,
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
        }

        if options.showsMinimap != sourceEditorView.isMinimapShown {
            if options.showsMinimap {
                sourceEditorView.installMinimap()
            } else {
                sourceEditorView.uninstallMinimap()
            }
        }

        if options.showsInsertionPoint != previousOptions.showsInsertionPoint {
            sourceEditorView.hideCursorWhenEditingDisabled = !options.showsInsertionPoint
        }

        if options.showsMarkSeparators {
            sourceEditorView.showMarkSeparators()
        } else {
            sourceEditorView.hideMarkSeparators()
        }
    }

    func showFindInterface(query: String, pattern: SourceEditorBridgingFindPattern, isCaseSensitive: Bool) {
        // The find interaction answers only for the first responder, as the system's ⌘F does. When
        // the view cannot become it the navigator is still presented; it just finds nothing.
        _ = sourceEditorView.becomeFirstResponder()
        let findInteraction = sourceEditorView.findInteraction
        if !query.isEmpty {
            findInteraction.searchText = query
        }
        findInteraction.presentFindNavigator(showingReplace: false)
    }
}

// MARK: - Reading Position

extension UIKitSourceEditorBridge: SourceEditorViewDelegate {
    /// The first layout after `setSource` is when the new text has lines to scroll to.
    func sourceEditorViewDidFinishLayingOutLines(_ editor: SourceEditorView) {
        guard let firstVisibleLine = pendingFirstVisibleLine else { return }
        pendingFirstVisibleLine = nil
        _ = sourceEditorView.scrollToLine(firstVisibleLine, column: 0, animated: false, forceFullView: true)
    }
}

// MARK: - Minimap Landmark Icons

extension UIKitSourceEditorBridge: MinimapLandmarkIconProvider {
    private static let iconPointSize: CGFloat = 14

    func icon(for landmarkType: LandmarkType) -> CGImage? {
        guard let minimapLandmarkIconProvider,
              let image = minimapLandmarkIconProvider.sourceEditorBridge(
                  self,
                  minimapIconForLandmarkOfKind: SourceEditorBridgeLookup.landmarkKind(for: landmarkType),
                  pointSize: Self.iconPointSize
              )
        else { return nil }
        let size = CGSize(width: Self.iconPointSize, height: Self.iconPointSize)
        let format = UIGraphicsImageRendererFormat(for: sourceEditorView.traitCollection)
        let renderedImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return renderedImage.cgImage
    }
}

#endif
