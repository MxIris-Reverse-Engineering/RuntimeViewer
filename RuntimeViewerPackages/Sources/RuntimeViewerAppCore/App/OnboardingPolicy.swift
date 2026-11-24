#if os(macOS)

import Foundation

/// Which onboarding page a launch of the macOS app shows (proposal `onboarding-pages`).
///
/// The welcome page goes to someone who has never used the app, told apart by the settings: only
/// someone who has used it has stored settings (`SettingsAccess.didFindStoredSettingsOnLoad`). What's New
/// goes to everyone else, once per feature release, when the catalog has a page for it. The release of
/// the last page the user continued from is remembered (`AppDefaults.lastPresentedOnboardingRelease`),
/// and the welcome page records the current release too, so What's New does not follow it.
///
/// The app's `OnboardingController` shows the page; this type only decides, so that a test can.
public enum OnboardingPolicy {
    /// - Parameters:
    ///   - currentRelease: The feature release of the running app.
    ///   - lastPresentedRelease: The release of the last page the user continued from, or `nil`.
    ///   - hasStoredSettings: Whether the launch found stored settings.
    ///   - catalog: The pages there are.
    /// - Returns: `nil` to show nothing.
    public static func pageForLaunch(
        currentRelease: FeatureRelease,
        lastPresentedRelease: FeatureRelease?,
        hasStoredSettings: Bool,
        catalog: OnboardingCatalog
    ) -> OnboardingPage? {
        if let lastPresentedRelease {
            guard lastPresentedRelease < currentRelease else { return nil }
            return catalog.whatsNewPages[currentRelease]
        }
        guard hasStoredSettings else { return catalog.welcomePage }
        return catalog.whatsNewPages[currentRelease]
    }
}

#endif
