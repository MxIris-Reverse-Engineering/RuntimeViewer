#if os(macOS)

import Testing
@testable import RuntimeViewerAppCore

/// Which onboarding page a launch shows: the welcome page to someone who has never used the app, What's
/// New once per feature release to everyone else (proposal `onboarding-pages`).
@Suite("Onboarding policy")
struct OnboardingPolicyTests {
    private static let release30 = FeatureRelease(major: 3, minor: 0)
    private static let release31 = FeatureRelease(major: 3, minor: 1)
    private static let release32 = FeatureRelease(major: 3, minor: 2)

    /// A catalog with What's New for 3.0 and 3.1 only.
    private static let catalog = OnboardingCatalog(
        welcomePage: OnboardingPage(kind: .welcome, title: "Welcome", image: .appIcon, features: []),
        whatsNewPages: [
            release30: OnboardingPage(kind: .whatsNew(release30), title: "3.0", features: []),
            release31: OnboardingPage(kind: .whatsNew(release31), title: "3.1", features: []),
        ]
    )

    private static func kind(
        currentRelease: FeatureRelease,
        lastPresentedRelease: FeatureRelease?,
        hasStoredSettings: Bool
    ) -> OnboardingPage.Kind? {
        OnboardingPolicy.pageForLaunch(
            currentRelease: currentRelease,
            lastPresentedRelease: lastPresentedRelease,
            hasStoredSettings: hasStoredSettings,
            catalog: catalog
        )?.kind
    }

    @Test("a first launch without stored settings shows the welcome page")
    func firstLaunchWithoutStoredSettingsShowsWelcomePage() {
        #expect(Self.kind(currentRelease: Self.release31, lastPresentedRelease: nil, hasStoredSettings: false) == .welcome)
        // Even for a release the catalog has no What's New for.
        #expect(Self.kind(currentRelease: Self.release32, lastPresentedRelease: nil, hasStoredSettings: false) == .welcome)
    }

    @Test("a first launch with stored settings shows the current release's What's New")
    func firstLaunchWithStoredSettingsShowsCurrentWhatsNew() {
        #expect(Self.kind(currentRelease: Self.release30, lastPresentedRelease: nil, hasStoredSettings: true) == .whatsNew(Self.release30))
    }

    @Test("a launch after updating shows the new release's What's New")
    func launchAfterUpdatingShowsWhatsNewOfNewRelease() {
        #expect(Self.kind(currentRelease: Self.release31, lastPresentedRelease: Self.release30, hasStoredSettings: true) == .whatsNew(Self.release31))
        // The record decides, not the settings, once there is one.
        #expect(Self.kind(currentRelease: Self.release31, lastPresentedRelease: Self.release30, hasStoredSettings: false) == .whatsNew(Self.release31))
    }

    @Test("a launch of the release already presented shows nothing")
    func launchOfSameReleaseShowsNothing() {
        #expect(Self.kind(currentRelease: Self.release30, lastPresentedRelease: Self.release30, hasStoredSettings: true) == nil)
        #expect(Self.kind(currentRelease: Self.release30, lastPresentedRelease: Self.release30, hasStoredSettings: false) == nil)
    }

    @Test("a launch after downgrading shows nothing")
    func launchAfterDowngradingShowsNothing() {
        #expect(Self.kind(currentRelease: Self.release30, lastPresentedRelease: Self.release31, hasStoredSettings: true) == nil)
    }

    @Test("a release without What's New shows nothing")
    func releaseWithoutWhatsNewShowsNothing() {
        #expect(Self.kind(currentRelease: Self.release32, lastPresentedRelease: Self.release31, hasStoredSettings: true) == nil)
        #expect(Self.kind(currentRelease: Self.release32, lastPresentedRelease: nil, hasStoredSettings: true) == nil)
    }
}

#endif
