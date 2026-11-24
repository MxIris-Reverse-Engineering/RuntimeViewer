#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerAppCore

/// The feature release onboarding pages are keyed by: the major and minor parts of the marketing
/// version (proposal `onboarding-pages`).
@Suite("Feature release")
struct FeatureReleaseTests {
    @Test("parses the major and minor parts of a marketing version", arguments: ["3.0.0", "3.0", "3.0.1", "3.0.12"])
    func parsesMajorAndMinorOfMarketingVersion(_ marketingVersion: String) {
        #expect(FeatureRelease(marketingVersion: marketingVersion) == FeatureRelease(major: 3, minor: 0))
    }

    @Test("rejects a version without two numbers", arguments: ["", "3", "3.", ".0", "three.zero", "3.x.0", "-1.0"])
    func rejectsVersionWithoutTwoNumbers(_ marketingVersion: String) {
        #expect(FeatureRelease(marketingVersion: marketingVersion) == nil)
    }

    @Test("orders by major, then minor")
    func ordersByMajorThenMinor() {
        #expect(FeatureRelease(major: 2, minor: 9) < FeatureRelease(major: 3, minor: 0))
        #expect(FeatureRelease(major: 3, minor: 0) < FeatureRelease(major: 3, minor: 1))
        #expect(FeatureRelease(major: 3, minor: 10) > FeatureRelease(major: 3, minor: 9))
        #expect(!(FeatureRelease(major: 3, minor: 0) < FeatureRelease(major: 3, minor: 0)))
    }

    @Test("describes itself as major.minor")
    func describesItselfAsMajorDotMinor() {
        #expect(FeatureRelease(major: 3, minor: 1).description == "3.1")
    }

    @Test("round-trips through AppDefaults")
    func roundTripsThroughAppDefaults() {
        let appDefaults = AppDefaults(
            storageDirectoryURL: AppDefaults.makeTemporaryStorageDirectoryURL(label: "feature-release"),
            userDefaultsNamespace: .makeIsolated()
        )
        #expect(appDefaults.lastPresentedOnboardingRelease == nil)

        appDefaults.lastPresentedOnboardingRelease = FeatureRelease(major: 3, minor: 0)

        #expect(appDefaults.lastPresentedOnboardingRelease == FeatureRelease(major: 3, minor: 0))
    }
}

#endif
