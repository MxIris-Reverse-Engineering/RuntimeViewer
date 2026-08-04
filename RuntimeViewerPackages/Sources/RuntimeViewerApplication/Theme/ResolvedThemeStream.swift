#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import RxSwift
import Dependencies
import DependenciesMacros
import RuntimeViewerArchitectures
@preconcurrency import RuntimeViewerSettings

/// Single shared `Observable<ResolvedTheme>` driven off `Settings.theme`.
///
/// Without this, each `ContentTextViewModel` (one per active document scene)
/// installed its own `Observable.tracking { ResolvedTheme(settings:) }.share(...)`
/// chain. Editing any custom preset re-allocated a full `ResolvedTheme`
/// (14 colors + 2 dictionaries) once per open document even when
/// `distinctUntilChanged` then discarded all but one of them. Hoisting the
/// tracking chain into a single dependency keeps the rebuild cost flat
/// regardless of how many documents are open.
@MainActor
public final class ResolvedThemeStream {
    fileprivate static let shared = ResolvedThemeStream()

    /// Multicast theme stream. Subscribers see the current value immediately
    /// (replay 1) and one new value per distinct settings change. The
    /// subscription is held with `.forever` scope so the tracking chain
    /// remains armed across document opens/closes.
    public let observable: Observable<ResolvedTheme>

    private init() {
        // Resolve the Settings instance once, outside the tracking closure:
        // the tracking bridge re-runs `access` on a bare main-queue hop
        // (task-locals lost), so a `@Dependency` resolution inside the
        // closure re-resolves against the ambient default context — in a
        // test process that is `.test`, which silently swaps in a different
        // Settings instance and kills the tracking chain after the first
        // re-arm. See `Observable.tracking`'s documentation.
        @Dependency(\.settings) var settings
        let trackedSettings = settings
        observable = Observable<ResolvedTheme>
            .tracking {
                ResolvedTheme(settings: trackedSettings)
            }
            .distinctUntilChanged()
            .share(replay: 1, scope: .forever)
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { ResolvedThemeStream.shared })
    public var resolvedThemeStream: ResolvedThemeStream
}
#endif
