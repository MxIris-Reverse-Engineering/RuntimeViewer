import Foundation

/// Timings shared by every pane that shows a loading placeholder, so panes
/// that sit next to each other behave as one thing rather than three.
///
/// See `ObservableType.withLoadingPlaceholder(_:appearsAfter:staysAtLeast:)`
/// for what each value governs.
public enum LoadingPlaceholderTiming {
    /// Work that beats this shows no placeholder at all — its content simply
    /// swaps in. Set below the threshold where a wait is perceived as a wait,
    /// so a warm cache lookup never flashes a placeholder.
    public static let appearsAfter: TimeInterval = 0.15

    /// Once a placeholder is up it stays at least this long, so work landing
    /// just past `appearsAfter` cannot make it blink for a frame.
    public static let staysAtLeast: TimeInterval = 0.3
}
