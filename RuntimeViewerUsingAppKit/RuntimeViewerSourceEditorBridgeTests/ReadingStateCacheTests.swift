// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers `ReadingStateCache` on its own, with a state type of the test's choosing: the cache is
/// generic so that the macOS bridge can keep folds and a scroll position and the iOS bridge only a
/// content offset, and what it promises — the state of the text it was recorded for, the least
/// recently used text dropped first — must hold whatever it keeps.
@Suite("ReadingStateCache")
struct ReadingStateCacheTests {
    private typealias Cache = ReadingStateCache<Int>

    @Test func restoresTheStateOfTheTextItWasRecordedFor() {
        var cache = Cache()
        let firstKey = Cache.Key(source: "class First {}", isDecorated: false)
        let secondKey = Cache.Key(source: "class Second {}", isDecorated: false)
        cache.store(1, for: firstKey)
        cache.store(2, for: secondKey)

        #expect(cache.state(for: firstKey) == 1)
        #expect(cache.state(for: secondKey) == 2)
    }

    @Test func keepsDecoratedAndPlainRenderingsOfOneTextApart() {
        var cache = Cache()
        cache.store(1, for: Cache.Key(source: "class Widget {}", isDecorated: true))

        #expect(cache.state(for: Cache.Key(source: "class Widget {}", isDecorated: false)) == nil)
    }

    @Test func dropsTheLeastRecentlyUsedTextWhenFull() {
        var cache = Cache(capacity: 2)
        let firstKey = Cache.Key(source: "first", isDecorated: false)
        let secondKey = Cache.Key(source: "second", isDecorated: false)
        let thirdKey = Cache.Key(source: "third", isDecorated: false)
        cache.store(1, for: firstKey)
        cache.store(2, for: secondKey)
        // Reading the first makes the second the least recently used.
        _ = cache.state(for: firstKey)
        cache.store(3, for: thirdKey)

        #expect(cache.state(for: firstKey) == 1)
        #expect(cache.state(for: secondKey) == nil)
        #expect(cache.state(for: thirdKey) == 3)
    }
}

#endif
