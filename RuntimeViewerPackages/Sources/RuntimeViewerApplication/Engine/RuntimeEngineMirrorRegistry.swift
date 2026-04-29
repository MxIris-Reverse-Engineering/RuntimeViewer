import Foundation
import OrderedCollections
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Pure state container for the per-source mirror reconcile logic.
///
/// Splits the dictionary writes that used to live inline in
/// `RuntimeEngineManager.handleEngineListChanged` and the two cleanup paths,
/// so the reconcile rules can be exercised by unit tests without spinning up
/// the full network stack.
///
/// Threading: every method is `@MainActor` isolated. All callers must hop to
/// the main actor before invoking; the type does not provide its own lock.
@MainActor
public final class RuntimeEngineMirrorRegistry {

    public typealias EngineFactory = (RemoteEngineDescriptor) -> RuntimeEngine

    /// Mirrored engine instances keyed by descriptor `engineID`.
    public private(set) var engines: OrderedDictionary<String, RuntimeEngine> = [:]

    /// Maps a mirrored engine's `engineID` to the direct upstream host that reported it
    /// (i.e. the peer we received the descriptor from). Two mirrored engines with the
    /// same originating host may have different owners if they arrived via different peers.
    /// First-come-first-served: if two peers report the same engineID, the first one owns
    /// it and subsequent duplicates are ignored until the owner drops it.
    public private(set) var ownership: [String: String] = [:]

    /// Last descriptor ID set received from each direct upstream, keyed by upstream host ID.
    /// Used for per-source dedup: a repeat push from source B that matches B's previous
    /// payload is skipped, without any interaction with other sources' state.
    public private(set) var lastDescriptorIDsBySource: [String: Set<String>] = [:]

    public init() {}

    // MARK: - Reconcile

    public enum ReconcileOutcome: Equatable {
        case skippedDuplicate
        case applied(removed: [Removal], added: [Addition])

        public struct Removal: Equatable {
            public let engineID: String
            public let engine: RuntimeEngine
            public static func == (lhs: Removal, rhs: Removal) -> Bool {
                lhs.engineID == rhs.engineID && lhs.engine === rhs.engine
            }
        }

        public struct Addition: Equatable {
            public let descriptor: RemoteEngineDescriptor
            public let engine: RuntimeEngine
            public static func == (lhs: Addition, rhs: Addition) -> Bool {
                lhs.descriptor.engineID == rhs.descriptor.engineID && lhs.engine === rhs.engine
            }
        }
    }

    /// Reconcile descriptors from a single direct upstream.
    ///
    /// Steps:
    /// 1. Drop descriptors whose `originChain` already contains `localInstanceID` (cycle).
    /// 2. Per-source dedup: if this source's last payload was identical, skip everything.
    /// 3. Per-source reconcile: remove engines previously owned by this source that no
    ///    longer appear in the new payload.
    /// 4. Add new engines (first-come-first-served — skip if engineID already owned).
    @discardableResult
    public func reconcile(
        descriptors: [RemoteEngineDescriptor],
        fromHostID sourceHostID: String,
        localInstanceID: String,
        engineFactory: EngineFactory
    ) -> ReconcileOutcome {
        let filteredDescriptors = descriptors.filter { descriptor in
            !descriptor.originChain.contains(localInstanceID)
        }

        let newIDSet = Set(filteredDescriptors.map(\.engineID))
        let previousIDSet = lastDescriptorIDsBySource[sourceHostID] ?? []
        if newIDSet == previousIDSet {
            return .skippedDuplicate
        }
        lastDescriptorIDsBySource[sourceHostID] = newIDSet

        let currentIDsFromThisSource = Set(
            ownership.compactMap { (id, ownerHostID) in
                ownerHostID == sourceHostID ? id : nil
            }
        )

        var removals: [ReconcileOutcome.Removal] = []
        for id in currentIDsFromThisSource.subtracting(newIDSet) {
            if let engine = engines.removeValue(forKey: id) {
                removals.append(.init(engineID: id, engine: engine))
            }
            ownership.removeValue(forKey: id)
        }

        var additions: [ReconcileOutcome.Addition] = []
        for descriptor in filteredDescriptors {
            guard engines[descriptor.engineID] == nil else { continue }
            let engine = engineFactory(descriptor)
            engines[descriptor.engineID] = engine
            ownership[descriptor.engineID] = sourceHostID
            additions.append(.init(descriptor: descriptor, engine: engine))
        }

        return .applied(removed: removals, added: additions)
    }

    // MARK: - Cleanup

    /// Case 1: the disconnected engine is itself a mirrored entry.
    /// Removes only that specific entry; does not touch dedup cache or other ownership.
    @discardableResult
    public func clearOwnMirror(matching engine: RuntimeEngine) -> [ReconcileOutcome.Removal] {
        let ownIDs = engines.compactMap { (id, mirroredEngine) in
            mirroredEngine === engine ? id : nil
        }
        var removals: [ReconcileOutcome.Removal] = []
        for id in ownIDs {
            if let mirrored = engines.removeValue(forKey: id) {
                removals.append(.init(engineID: id, engine: mirrored))
            }
            ownership.removeValue(forKey: id)
        }
        return removals
    }

    /// Case 2: the disconnected engine is a direct peer that had pushed descriptors
    /// to us. Remove every mirrored engine whose recorded direct upstream matches
    /// the peer's `hostID`, including engines transitively mirrored through the peer
    /// (e.g. A → B → C: if B disconnects, drop the mirror of C). Also clears the
    /// dedup cache for that source so the next reconnect re-pushes a fresh payload.
    @discardableResult
    public func clearAllOwnedBy(hostID: String) -> [ReconcileOutcome.Removal] {
        let affectedIDs = ownership.compactMap { (id, ownerHostID) in
            ownerHostID == hostID ? id : nil
        }
        var removals: [ReconcileOutcome.Removal] = []
        for id in affectedIDs {
            if let mirrored = engines.removeValue(forKey: id) {
                removals.append(.init(engineID: id, engine: mirrored))
            }
            ownership.removeValue(forKey: id)
        }
        lastDescriptorIDsBySource.removeValue(forKey: hostID)
        return removals
    }
}
