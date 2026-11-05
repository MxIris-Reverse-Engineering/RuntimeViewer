import Foundation
import Semantic

/// How a corpus build request ended, as it travels between engines.
///
/// The ends that are not a summary are values rather than thrown errors so
/// they cross every transport, and any number of relaying engines, intact: a
/// thrown error crosses a connection as its description only, and a
/// `CancellationError` that arrives as a description reads as a failure.
/// `RuntimeEngine.buildInterfaceCorpus` turns them back into errors in the
/// caller's process.
enum RuntimeInterfaceCorpusBuildOutcome: Hashable, Codable, Sendable {
    case built(RuntimeInterfaceCorpusBuildSummary)
    /// The store gave the build up for every subscriber — the image was
    /// evicted, another document asked for it under another transformer — or
    /// this caller withdrew.
    case cancelled
    /// The image does not have both of its sections built, so there is
    /// nothing to print; nothing was attempted.
    case imageNotIndexed
}
