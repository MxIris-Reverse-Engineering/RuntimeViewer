import Foundation
import RuntimeViewerCore

/// What a preparation request came to: a value, not a thrown error, so that
/// a cancellation or an image that is not indexed survives the trip to a host
/// in another process as what it is.
enum RuntimeCrossReferencePreparationOutcome: Codable, Sendable {
    case prepared(RuntimeCrossReferencePreparation)
    case cancelled
    case imageNotIndexed
}
