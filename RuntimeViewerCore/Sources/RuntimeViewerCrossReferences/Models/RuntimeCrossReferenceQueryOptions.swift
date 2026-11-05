import Foundation
import RuntimeViewerCore

public struct RuntimeCrossReferenceQueryOptions: Hashable, Codable, Sendable {
    /// Keep calls to retains, releases, outlined value operations and other
    /// runtime helpers among the callees. Callers are never filtered: a query
    /// for a helper's callers asks for exactly those.
    public var includesRuntimeHelperCalls: Bool
    /// Keep only sends whose receiver is known to be this class, or is
    /// unknown. References that are not sends are kept.
    public var receiverClassName: String?
    /// Stop after this many references; the result is then incomplete. A scan
    /// across images stops as soon as it has them, so which ones come back
    /// depends on which images finished first.
    public var resultLimit: Int?
    /// How many images the engine's process scans at the same time, each
    /// keeping a core busy, across every query it runs. The process keeps the
    /// count the latest query brought; `nil` leaves it as it is — four, until
    /// a query sets another. The app sends its Max Concurrent Scans setting.
    public var maximumConcurrentScans: Int?
    /// When set, every image the query reads is answered from its prepared
    /// cross references (``RuntimeEngine/prepareCrossReferences(forImageAt:options:reportProgress:)``)
    /// — prepared now, ahead of those queued, for an image that has none —
    /// and the engine's process keeps at most this many bytes of them. `nil`
    /// scans each image for the query alone, as a query always did. The app
    /// sends its Resident Limit while Keep Cross References Ready is on.
    public var preparedIndexByteLimit: Int?

    public init(
        includesRuntimeHelperCalls: Bool = false,
        receiverClassName: String? = nil,
        resultLimit: Int? = nil,
        maximumConcurrentScans: Int? = nil,
        preparedIndexByteLimit: Int? = nil
    ) {
        self.includesRuntimeHelperCalls = includesRuntimeHelperCalls
        self.receiverClassName = receiverClassName
        self.resultLimit = resultLimit
        self.maximumConcurrentScans = maximumConcurrentScans
        self.preparedIndexByteLimit = preparedIndexByteLimit
    }
}
