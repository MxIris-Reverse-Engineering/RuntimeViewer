// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them.
#if arch(arm64) && canImport(SourceEditor)

import Foundation
internal import SourceEditor

/// Tells the editor where else the identifier under the insertion point appears, which it then
/// draws behind the text: Xcode's highlight of the selected symbol.
///
/// The editor asks, but nothing in the frameworks answers. `SelectedSymbolHighlight` takes the
/// references from the language service once the insertion point has rested for
/// `SourceEditorView.selectedSymbolHighlightDelay`, and `SourceModelLanguageService` has none of
/// its own: its `referencesToSymbolAtPosition` hands the question to its `hostExtension` and
/// answers nothing without one (26.6.3; the witness is the dispatch thunk at 0x54CDC). In Xcode
/// that host is the IDE, with the index behind it.
///
/// The pane shows one generated interface at a time, in which the same identifier spelled the same
/// way is the same name to the reader. So the answer is a search of the text for the identifier,
/// keeping each hit the editor's own parse also takes for a whole identifier token — which leaves
/// out comments, strings and a name that is only part of a longer one.
final class SymbolOccurrenceProvider: LanguageServiceHostExtension {
    /// More than this many hits on one name stops the search: the editor draws only the visible
    /// ones anyway, and the cap keeps a very common short name in a very long interface from
    /// costing a noticeable pause on the main thread.
    private static let maximumOccurrenceCount = 5000

    /// The view whose current data source the questions are about. The language service a
    /// question comes from belongs to that data source: every `setSource` installs a new one
    /// with this provider as its host.
    weak var sourceEditorView: SourceEditorView?

    /// The text last passed to `setSource`, which the data source holds too, kept as an
    /// `NSString` so the search runs in the UTF-16 offsets the data source converts.
    private var source: NSString = ""

    func load(source: String) {
        self.source = source as NSString
    }

    func referencesToSymbolAtPosition(
        _ position: SourceEditorPosition,
        cancelledBlock: (() -> Bool)?,
        completionBlock: @escaping ([Range<SourceEditorPosition>]) -> Void
    ) {
        completionBlock(occurrences(ofIdentifierAt: position))
    }

    // The two requirements without a default. Answering nil is what the language service does
    // itself when it has no host (`provideDiagnostics(completionBlock:)`), so turning the host
    // on changes nothing about diagnostics.
    func cancelProvideDiagnosticsRequest() {}

    func provideDiagnostics(completionBlock: @escaping ([SourceEditorDiagnostic]?) -> Void) {
        completionBlock(nil)
    }

    /// Every whole identifier token spelled like the one at `position`, that one included, in
    /// the order they appear; empty when `position` is not on an identifier.
    func occurrences(ofIdentifierAt position: SourceEditorPosition) -> [Range<SourceEditorPosition>] {
        guard let dataSource = sourceEditorView?.dataSource,
              let identifierRange = identifierRange(at: position, in: dataSource)
        else { return [] }
        let name = dataSource.textInRange(identifierRange)
        guard !name.isEmpty else { return [] }

        var occurrences: [Range<SourceEditorPosition>] = []
        var searchRange = NSRange(location: 0, length: source.length)
        var lineHint = 0
        while occurrences.count < Self.maximumOccurrenceCount {
            let foundRange = source.range(of: name, options: .literal, range: searchRange)
            guard foundRange.location != NSNotFound else { break }
            searchRange = NSRange(location: NSMaxRange(foundRange), length: source.length - NSMaxRange(foundRange))

            let start = dataSource.positionFromInternalCharOffset(foundRange.location, lineHint: lineHint)
            lineHint = start.line
            let candidateRange = start ..< SourceEditorPosition(line: start.line, col: start.col + foundRange.length)
            // A hit counts only when the token the editor finds there is exactly this one: the
            // lookup returns the token the character at `start` belongs to.
            guard let (tokenType, tokenRange) = dataSource.tokenRangeAtPosition(start),
                  case .identifier? = tokenType,
                  tokenRange == candidateRange
            else { continue }
            occurrences.append(candidateRange)
        }
        return occurrences
    }

    /// The identifier token at `position`, or the one just before it.
    ///
    /// The lookup returns the token of the character *after* an insertion point, so a click on
    /// the right half of a name's last letter, which leaves the insertion point after the name,
    /// would otherwise find the punctuation that follows it.
    private func identifierRange(at position: SourceEditorPosition, in dataSource: SourceEditorDataSource) -> Range<SourceEditorPosition>? {
        var candidatePositions = [position]
        if position.col > 0 {
            candidatePositions.append(SourceEditorPosition(line: position.line, col: position.col - 1))
        }
        for candidatePosition in candidatePositions {
            guard let (tokenType, tokenRange) = dataSource.tokenRangeAtPosition(candidatePosition),
                  case .identifier? = tokenType,
                  tokenRange.lowerBound.line == tokenRange.upperBound.line,
                  tokenRange.lowerBound < tokenRange.upperBound
            else { continue }
            return tokenRange
        }
        return nil
    }
}

#endif
