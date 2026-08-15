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

    private let semanticColorProvider = SemanticColorProvider()

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
        sourceEditorView.layoutManager.addLayoutOverrideProvider(semanticColorProvider)
    }

    func setSource(_ source: NSAttributedString, languageIdentifier: String) {
        let language: SourceEditorLanguage? =
            switch languageIdentifier {
            case "swift": SourceModelEditorLanguage.swift
            case "objc": SourceModelEditorLanguage.objc
            default: nil
            }

        // The framework tokenizes plain text, so it only ever sees the string. The colors
        // the generator resolved from runtime metadata are applied on top, by line, through
        // the override provider.
        semanticColorProvider.load(from: source)
        sourceEditorView.dataSource = SourceEditorDataSource(
            usingMutableString: NSMutableString(string: source.string),
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

// MARK: - Semantic Coloring

extension SourceEditorBridge {
    /// Paints the generator's colors over the framework's own syntax coloring.
    ///
    /// The framework colors from a lexical scan of the plain text, which cannot tell a class
    /// name from any other identifier — `NSString` comes out as plain text. RuntimeViewer
    /// already knows what every identifier is, because the interface was rendered from runtime
    /// metadata, and that knowledge is carried in the attributed string's color runs. This
    /// replays those runs.
    ///
    /// Overriding attributes is far cheaper than the alternative of supplying a whole
    /// `SourceEditorLanguageService`, which is a 48-requirement protocol; this route needs two
    /// methods, one of which has a default implementation.
    fileprivate final class SemanticColorProvider: NSObject, TextAttributeOverrideProvider {
        /// Indexed by line. Each entry holds column ranges relative to that line's start,
        /// which is the coordinate space `textAttributeOverridesForLine` works in.
        private var overridesByLine: [[SourceEditorTextAttributeOverride]] = []

        /// These colors are the point of the feature, so nothing else should be able to take
        /// them back. The framework's own gutter sits at `.low`.
        let priority: LayoutOverrideProviderPriority = .high

        func load(from attributedString: NSAttributedString) {
            let text = attributedString.string as NSString

            // Both bounds per line: where it starts, and how long its *content* is. The
            // content length excludes the line terminator, and that distinction is not
            // cosmetic — the framework traps on a column range that runs past the end of the
            // line ("specified column range out of bounds"), so a run that swallowed the
            // trailing newline would take the app down.
            var lineStarts: [Int] = []
            var lineContentLengths: [Int] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                lineStarts.append(range.location)
                lineContentLengths.append(range.length)
            }
            if lineStarts.isEmpty {
                lineStarts = [0]
                lineContentLengths = [0]
            }
            var overridesByLine: [[SourceEditorTextAttributeOverride]] = Array(repeating: [], count: lineStarts.count)

            attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length)) { attributes, range, _ in
                guard let foregroundColor = attributes[.foregroundColor] else { return }
                let overrideAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: foregroundColor]

                // A run can straddle line boundaries; split it so every piece is expressed in
                // its own line's columns.
                var lineIndex = Self.lineIndex(containing: range.location, in: lineStarts)
                var remaining = range
                while remaining.length > 0, lineIndex < lineStarts.count {
                    let lineStart = lineStarts[lineIndex]
                    let lineContentEnd = lineStart + lineContentLengths[lineIndex]
                    let pieceStart = max(remaining.location, lineStart)
                    let pieceEnd = min(remaining.location + remaining.length, lineContentEnd)
                    if pieceEnd > pieceStart {
                        overridesByLine[lineIndex].append(
                            SourceEditorTextAttributeOverride(
                                range: (pieceStart - lineStart) ..< (pieceEnd - lineStart),
                                attr: overrideAttributes
                            )
                        )
                    }
                    // Advance past this line including its terminator, so the next iteration
                    // starts at the following line rather than re-clipping the same piece.
                    let nextLineStart = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : text.length
                    let consumedTo = min(remaining.location + remaining.length, nextLineStart)
                    remaining = NSRange(location: consumedTo, length: remaining.location + remaining.length - consumedTo)
                    lineIndex += 1
                }
            }

            self.overridesByLine = overridesByLine
        }

        func textAttributeOverridesForLine(_ line: Int, in layoutManager: SourceEditorLayoutManager) -> [SourceEditorTextAttributeOverride] {
            guard line >= 0, line < overridesByLine.count else { return [] }
            return overridesByLine[line]
        }

        private static func lineIndex(containing characterIndex: Int, in lineStarts: [Int]) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= characterIndex {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return low
        }
    }
}
