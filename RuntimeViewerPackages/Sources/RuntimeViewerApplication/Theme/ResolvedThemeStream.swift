#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import RxSwift
import Dependencies
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
        observable = Observable<ResolvedTheme>
            .tracking {
                @Dependency(\.settings) var settings
                return ResolvedTheme(settings: settings)
            }
            .distinctUntilChanged()
            .share(replay: 1, scope: .forever)
    }
}

// MARK: - Dependencies

private enum ResolvedThemeStreamKey: @preconcurrency DependencyKey {
    @MainActor static let liveValue = ResolvedThemeStream.shared
}

extension DependencyValues {
    public var resolvedThemeStream: ResolvedThemeStream {
        get { self[ResolvedThemeStreamKey.self] }
        set { self[ResolvedThemeStreamKey.self] = newValue }
    }
}
#endif
