import Foundation
import FoundationToolbox
import Semaphore

/// A null message type used when no payload is needed.
struct RuntimeMessageNull: Codable, Sendable {
    static let null = RuntimeMessageNull()
}
