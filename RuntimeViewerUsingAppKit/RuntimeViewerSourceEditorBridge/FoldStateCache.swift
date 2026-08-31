import Foundation

/// Remembers what was folded in each interface the editor has shown, so that leaving a class
/// and coming back does not silently discard the reader's folds.
///
/// The bridge has to unfold before every source swap — a fold outstanding across the swap
/// crashes the framework, see `SourceEditorBridge.setSource`. Saving the state first and
/// putting it back when the same text returns is what keeps that from also being a feature
/// regression.
///
/// Session-scoped on purpose: fold state describes one particular rendering of one particular
/// interface, and both the runtime metadata and the generation options behind it can differ by
/// the next launch. There is nothing here worth persisting.
struct FoldStateCache {
    /// Identifies the *text*, not the object it was rendered from.
    ///
    /// The bridge is handed a `String` and nothing else — no `RuntimeObject`, no generation
    /// options — which turns out to be the right level anyway: change any option that alters
    /// the rendering and the text changes with it, so the key changes and the stale state is
    /// simply never found. A key built from the object would have to be told about every
    /// option that feeds the generator, and would silently mismatch the day one was missed.
    ///
    /// `hashValue` is seeded per process, which is fine because the cache does not outlive the
    /// process. The character count rides along to make a collision need two coincidences
    /// rather than one; the framework's own guards catch what still gets through, turning it
    /// into "no folds restored" rather than anything worse.
    struct Key: Hashable {
        private let sourceHash: Int
        private let characterCount: Int

        init(source: String) {
            sourceHash = source.hashValue
            characterCount = source.count
        }
    }

    /// Enough to cover moving among a handful of classes and back. Each entry is a dictionary
    /// of line/column pairs — hundreds of bytes for a heavily folded interface — so the ceiling
    /// is about legibility, not memory.
    private let capacity: Int

    private var statesByKey: [Key: NSDictionary] = [:]

    /// Least-recently-used first. Small enough (`capacity` entries) that the linear scans below
    /// beat keeping a second index in sync.
    private var keysInUseOrder: [Key] = []

    init(capacity: Int = 24) {
        self.capacity = capacity
    }

    /// Stores `state` for `key`, dropping the least recently used entry when full.
    ///
    /// An empty fold list is stored like any other: "this interface had nothing folded" is a
    /// real answer, and skipping it would let an older, stale state stay behind and come back
    /// the next time the same text is shown.
    mutating func store(_ state: NSDictionary, for key: Key) {
        if statesByKey[key] == nil, keysInUseOrder.count == capacity, let oldest = keysInUseOrder.first {
            keysInUseOrder.removeFirst()
            statesByKey[oldest] = nil
        }
        statesByKey[key] = state
        moveToMostRecent(key)
    }

    /// The state stored for `key`, if any, marking it most recently used.
    mutating func state(for key: Key) -> NSDictionary? {
        guard let state = statesByKey[key] else { return nil }
        moveToMostRecent(key)
        return state
    }

    private mutating func moveToMostRecent(_ key: Key) {
        if let existingIndex = keysInUseOrder.firstIndex(of: key) {
            keysInUseOrder.remove(at: existingIndex)
        }
        keysInUseOrder.append(key)
    }
}
