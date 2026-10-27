import Foundation
import Observation

/// What the Indexing settings page shows of the app's derived data — where it
/// is and what it takes on disk — and what the page can do with it.
///
/// The app registers the live implementation, `RuntimeDerivedDataController`,
/// which measures and deletes through `RuntimeDerivedDataMaintenance`; in
/// previews and tests the default instance shows no location and does
/// nothing, so the page renders without the app layer present. Derived data
/// itself is written by the app's services only (proposal
/// `derived-data`); this is the app's side.
@Observable
@MainActor
public final class DerivedDataClient {
    /// `~/Library/Caches/<bundle identifier>/DerivedData`; `nil` outside a
    /// RuntimeViewer application.
    public private(set) var location: URL?

    /// What it took on disk when last measured; `nil` before the first
    /// measurement and while one runs.
    public private(set) var allocatedByteCount: Int64?

    /// Measures again. The page asks as it appears, and after a deletion.
    public var refresh: @MainActor () -> Void

    /// Reveals the location in the Finder — its parent when it does not
    /// exist yet.
    public var showInFinder: @MainActor () -> Void

    /// Asks before deleting everything there, then deletes it.
    public var delete: @MainActor () -> Void

    public init(
        location: URL? = nil,
        allocatedByteCount: Int64? = nil,
        refresh: @escaping @MainActor () -> Void = {},
        showInFinder: @escaping @MainActor () -> Void = {},
        delete: @escaping @MainActor () -> Void = {}
    ) {
        self.location = location
        self.allocatedByteCount = allocatedByteCount
        self.refresh = refresh
        self.showInFinder = showInFinder
        self.delete = delete
    }

    public func setLocation(_ location: URL?) {
        self.location = location
    }

    public func setAllocatedByteCount(_ allocatedByteCount: Int64?) {
        self.allocatedByteCount = allocatedByteCount
    }
}
