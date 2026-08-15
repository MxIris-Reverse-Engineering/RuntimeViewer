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
        @Dependency(\.settings) var settings
        let trackedSettings = settings
        observable = Observable<ResolvedTheme>
            .tracking {
                // `tracking` runs this synchronously on whichever thread
                // subscribes, and `SettingsAccess` is main-actor isolated, so
                // reading it from anywhere else races Observation's registrar.
                // Every subscriber attaches on the main thread today; assert
                // that rather than leave it to the `@preconcurrency` import,
                // which silences the diagnostic without making it true.
                MainActor.assumeIsolated {
                    ResolvedTheme(settings: trackedSettings.current)
                }
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
