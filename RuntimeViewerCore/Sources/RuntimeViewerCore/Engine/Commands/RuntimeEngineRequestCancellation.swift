import Foundation
import FoundationToolbox

// MARK: - Wire

/// The payload of `RuntimeEngine.CommandName.cancelRequest`: the identifier
/// the requesting peer minted for a request it no longer wants.
struct RuntimeEngineRequestCancellation: Codable, Sendable {
    let requestIdentifier: String
}
