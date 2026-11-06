// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them.
#if arch(arm64) && canImport(SourceEditor)

import Foundation

/// Remembers where the reader was in each interface the editor has shown — what was folded and
/// how far down it was scrolled — so that leaving a class and coming back finds it as it was left.
///
/// The bridge has to unfold before every source swap — a fold outstanding across the swap
/// crashes the framework, see `SourceEditorBridge.setSource` — and every swap installs a new data
/// source, which starts at the top. Saving both first and putting them back when the same text
/// returns is what keeps that from losing the reader's place.
///
/// Session-scoped on purpose: the state describes one particular rendering of one particular
/// interface, and both the runtime metadata and the generation options behind it can differ by
/// the next launch. There is nothing here worth persisting.
struct ReadingStateCache {
    /// What the bridge saves for one text.
    struct ReadingState {
        /// `FoldingController.stateDictionaryForSaving`.
        let foldState: NSDictionary

        /// `SourceEditorView.scrollStateForStateRestoration()`: the line at the top of the visible
        /// area and how far into it the view is scrolled. Taken while the text's own folds are
        /// still in place, which is what the line is counted against when it comes back.
        let scrollPosition: (line: Int, offset: CGFloat)
    }

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

        /// Whether the text was shown with comment decorations. The same text folds differently
        /// with and without them — the decorations add collapsible rows — so turning comment tags
        /// on or off must not bring back the folds made the other way.
        private let isDecorated: Bool

        init(source: String, isDecorated: Bool) {
            sourceHash = source.hashValue
            characterCount = source.count
            self.isDecorated = isDecorated
        }
    }

    /// Enough to cover moving among a handful of classes and back. Each entry is a dictionary
    /// of line/column pairs — hundreds of bytes for a heavily folded interface — and a scroll
    /// position, so the ceiling is about legibility, not memory.
    private let capacity: Int

    private var statesByKey: [Key: ReadingState] = [:]

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
    mutating func store(_ state: ReadingState, for key: Key) {
        if statesByKey[key] == nil, keysInUseOrder.count == capacity, let oldest = keysInUseOrder.first {
            keysInUseOrder.removeFirst()
            statesByKey[oldest] = nil
        }
        statesByKey[key] = state
        moveToMostRecent(key)
    }

    /// The state stored for `key`, if any, marking it most recently used.
    mutating func state(for key: Key) -> ReadingState? {
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

#endif
