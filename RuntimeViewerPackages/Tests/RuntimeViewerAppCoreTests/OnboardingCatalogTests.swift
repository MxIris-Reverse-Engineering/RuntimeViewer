#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerAppCore

/// RuntimeViewer's onboarding pages, and the rule that a feature release's version bump comes with its
/// What's New (proposal `onboarding-pages`).
@Suite("Onboarding catalog")
struct OnboardingCatalogTests {
    /// `Configurations/Version.xcconfig`, the one place a release sets its version.
    private static let versionConfigurationURL = URL(filePath: #filePath)
        .deletingLastPathComponent() // RuntimeViewerAppCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // RuntimeViewerPackages
        .deletingLastPathComponent() // the repository
        .appending(path: "Configurations/Version.xcconfig")

    private static func marketingVersion() throws -> String {
        let contents = try String(contentsOf: versionConfigurationURL, encoding: .utf8)
        let line = try #require(
            contents.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("MARKETING_VERSION") }
        )
        let value = try #require(line.split(separator: "=", maxSplits: 1).last)
        return value.trimmingCharacters(in: .whitespaces)
    }

    @Test("has What's New for the feature release of MARKETING_VERSION in Version.xcconfig")
    func catalogHasWhatsNewForMarketingVersionInVersionXcconfig() throws {
        let marketingVersion = try Self.marketingVersion()
        let release = try #require(FeatureRelease(marketingVersion: marketingVersion))

        let page = OnboardingCatalog.runtimeViewer.whatsNewPages[release]

        #expect(
            page != nil,
            "MARKETING_VERSION is \(marketingVersion): add What's New for \(release) to OnboardingCatalog.runtimeViewer"
        )
    }

    @Test("files every What's New page under its own release")
    func whatsNewPagesAreFiledUnderTheirRelease() {
        for (release, page) in OnboardingCatalog.runtimeViewer.whatsNewPages {
            #expect(page.kind == .whatsNew(release))
        }
        #expect(OnboardingCatalog.runtimeViewer.welcomePage.kind == .welcome)
    }

    @Test("lists between one and six features on every page")
    func everyPageListsBetweenOneAndSixFeatures() {
        let catalog = OnboardingCatalog.runtimeViewer
        for page in [catalog.welcomePage] + Array(catalog.whatsNewPages.values) {
            #expect((1 ... 6).contains(page.features.count), "\(page.title) lists \(page.features.count) features")
        }
    }

    @Test("falls back to the latest What's New before a release that has none")
    func latestWhatsNewPageFallsBackToEarlierRelease() {
        let release30 = FeatureRelease(major: 3, minor: 0)
        let release32 = FeatureRelease(major: 3, minor: 2)
        let catalog = OnboardingCatalog(
            welcomePage: OnboardingPage(kind: .welcome, title: "Welcome", image: .appIcon, features: []),
            whatsNewPages: [
                release30: OnboardingPage(kind: .whatsNew(release30), title: "3.0", features: []),
                release32: OnboardingPage(kind: .whatsNew(release32), title: "3.2", features: []),
            ]
        )

        #expect(catalog.latestWhatsNewPage(upTo: release30)?.kind == .whatsNew(release30))
        #expect(catalog.latestWhatsNewPage(upTo: FeatureRelease(major: 3, minor: 1))?.kind == .whatsNew(release30))
        #expect(catalog.latestWhatsNewPage(upTo: FeatureRelease(major: 4, minor: 0))?.kind == .whatsNew(release32))
        #expect(catalog.latestWhatsNewPage(upTo: FeatureRelease(major: 2, minor: 9)) == nil)
    }
}

#endif
