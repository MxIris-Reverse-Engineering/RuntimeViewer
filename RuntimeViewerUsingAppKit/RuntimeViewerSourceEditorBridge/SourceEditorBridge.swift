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

    weak var navigationDelegate: SourceEditorBridgingNavigationDelegate?

    var editorView: NSView { sourceEditorView }

    override init() {
        super.init()

        sourceEditorView.do {
            // Defaults to true, in which case the view takes ⌘-click as a multi-cursor
            // gesture and consumes it before any event consumer is offered the event.
            $0.enableCmdClickMultiCursor = false
            $0.isEditingEnabled = false
        }

        commandClickNavigator.bridge = self
        sourceEditorView.addEventConsumer(commandClickNavigator)
    }

    func setSource(_ source: String, languageIdentifier: String) {
        let language: SourceEditorLanguage? =
            switch languageIdentifier {
            case "swift": SourceModelEditorLanguage.swift
            case "objc": SourceModelEditorLanguage.objc
            default: nil
            }

        sourceEditorView.dataSource = SourceEditorDataSource(
            usingMutableString: NSMutableString(string: source),
            language: language,
            formattingOptions: SourceEditorFormattingOptions()
        )
    }

    func applyTheme(name: String, dictionary: NSDictionary, fontSizeModifier: Int) {
        guard let themeDictionary = dictionary as? [String: AnyHashable] else { return }
        let theme = SourceEditorTheme(name: name, dictionary: themeDictionary, fontSizeModifier: fontSizeModifier)
        sourceEditorView.colorTheme = theme
        sourceEditorView.fontTheme = theme
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

// MARK: - Convenience

extension NSObjectProtocol {
    /// Local stand-in for FrameworkToolbox's `do`, which the bundle does not link.
    fileprivate func `do`(_ body: (Self) -> Void) { body(self) }
}
