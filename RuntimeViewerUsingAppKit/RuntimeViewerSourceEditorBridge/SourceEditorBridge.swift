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

    weak var navigationDelegate: SourceEditorBridgingNavigationDelegate?

    var editorView: NSView { sourceEditorView }

    override init() {
        super.init()

        // Defaults to true, in which case the view takes ⌘-click as a multi-cursor
        // gesture and consumes it before any event consumer is offered the event.
        sourceEditorView.enableCmdClickMultiCursor = false
        sourceEditorView.isEditingEnabled = false

        // A gutter has to be installed before line numbers exist at all; the view ships
        // without one.
        let gutter = SourceEditorGutter()
        gutter.enableLineNumbers()
        gutter.emphasizeActiveLines = true
        sourceEditorView.gutter = gutter

        commandClickNavigator.bridge = self
        sourceEditorView.addEventConsumer(commandClickNavigator)
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

    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int) {
        guard let themeDictionary = dictionary as? [String: AnyHashable] else { return }
        let theme = SourceEditorTheme(name: name, dictionary: themeDictionary, fontSizeModifier: fontSizeModifier)
        sourceEditorView.colorTheme = theme
        sourceEditorView.fontTheme = theme
    }

    func applyBackgroundColor(_ backgroundColor: NSColor) {
        // Set alongside the theme's own background key rather than instead of it: the theme
        // drives what the editor paints behind text, this drives the view itself, and a
        // mismatch shows up as a differently-coloured band past the end of the document.
        sourceEditorView.backgroundColor = backgroundColor
    }

    func scrollToCharacterIndex(_ characterIndex: Int) {
        // TODO: needs SourceEditorView's scroll-to-position API reconstructed; the display
        // path works without it, so it is left unimplemented rather than half-guessed.
    }

    fileprivate func reportCommandClick(at position: SourceEditorPosition) {
        guard let navigationDelegate else { return }
        let dataSource = sourceEditorView.dataSource
        guard let (_, tokenRange) = dataSource.tokenRangeAtPosition(position) else { return }

        let lowerBound = characterIndex(of: tokenRange.lowerBound, in: dataSource)
        let upperBound = characterIndex(of: tokenRange.upperBound, in: dataSource)
        guard upperBound > lowerBound else { return }

        navigationDelegate.sourceEditorBridge(self, didCommandClickTokenIn: NSRange(location: lowerBound, length: upperBound - lowerBound))
    }

    /// A `SourceEditorPosition` is a line/column pair; the app indexes the same text by
    /// UTF-16 offset, which is what `NSAttributedString` uses.
    private func characterIndex(of position: SourceEditorPosition, in dataSource: SourceEditorDataSource) -> Int {
        let lineRange = dataSource.characterRangeForLineRange(NSRange(location: position.line, length: 1))
        return lineRange.location + position.col
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
