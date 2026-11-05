import Foundation
import Semantic

/// Why a text or member search stopped before reading every corpus it
/// covers.
public enum RuntimeInterfaceSearchStopReason: String, Codable, Hashable, Sendable {
    /// The regular expression spent the search's time budget backtracking:
    /// `(\w+)+\(` over a long identifier never finishes on its own.
    case regularExpressionTooExpensive
}
