import RuntimeViewerArchitectures

extension SharedSequenceConvertibleType where Element == NavigatorTextFilter {
    /// Holds each non-empty filter back for 150 ms and drops it when the next one comes sooner, for a field that reports
    /// every keystroke — the iOS search bar. An empty filter goes on at once, so clearing the field never waits. macOS
    /// needs none of it: its token field reports typing only once the user has paused for 0.2 seconds.
    ///
    /// It has to be `delay` on a single element, not `debounce`: `debounce` sends a pending element on the moment its
    /// sequence completes, and `.just` completes straight after its element, so `.just(…).debounce(…)` never delays
    /// anything.
    public func coalescingKeystrokes() -> SharedSequence<SharingStrategy, NavigatorTextFilter> {
        flatMapLatest { filter -> SharedSequence<SharingStrategy, NavigatorTextFilter> in
            if filter.isEmpty {
                return .just(filter)
            } else {
                return SharedSequence<SharingStrategy, NavigatorTextFilter>.just(filter).delay(.milliseconds(150))
            }
        }
    }
}
