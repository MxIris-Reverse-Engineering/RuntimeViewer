import UIKit
import Observation
import Dependencies
import DependenciesMacros
import RuntimeViewerSettings

/// Applies the Appearance setting — System, Light or Dark — to every window,
/// the counterpart of the macOS app's `AppearanceController`.
///
/// iOS has no app-wide appearance, so the setting goes on each window's
/// `overrideUserInterfaceStyle`: every connected scene's windows when the
/// setting changes, and a window created later through ``apply(to:)``.
@MainActor
final class AppearanceController {
    fileprivate static let shared = AppearanceController()

    @Dependency(\.settings) private var settings

    private var isFollowingSettings = false

    private init() {}

    /// Applies the setting to every window now and whenever it changes. Call
    /// once the settings are loaded.
    func start() {
        guard !isFollowingSettings else { return }
        isFollowingSettings = true
        followAppearanceSetting()
    }

    /// Gives a window the current appearance — for a window created after
    /// ``start()``.
    func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = userInterfaceStyle
    }

    private var userInterfaceStyle: UIUserInterfaceStyle {
        switch settings.general.appearance {
        case .system:
            .unspecified
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private func followAppearanceSetting() {
        withObservationTracking {
            applyToEveryWindow()
        } onChange: { [weak self] in
            // Observation calls this before the change commits; apply the new
            // value once it has.
            Task { @MainActor [weak self] in
                guard let self else { return }
                followAppearanceSetting()
            }
        }
    }

    private func applyToEveryWindow() {
        let style = userInterfaceStyle
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { AppearanceController.shared })
    var appearanceController: AppearanceController
}
