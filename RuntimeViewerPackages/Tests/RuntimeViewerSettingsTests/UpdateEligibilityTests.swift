import Testing
import Foundation
@testable import RuntimeViewerSettings

@Suite("UpdateEligibility")
struct UpdateEligibilityTests {
    private let numberedBuild = UpdateEligibility(currentVersion: "3.0.0", currentBuildNumber: "20261102.08.15")
    private let developmentBuild = UpdateEligibility(currentVersion: "3.0.0", currentBuildNumber: "1")

    @Test("an Xcode build of 3.0.0 is not offered 2.1.2")
    func developmentBuildRejectsOlderVersion() {
        // Sparkle alone offered it: build 1 is lower than 2.1.2's 20260815.06.34.
        #expect(!developmentBuild.allowsUpdate(toVersion: "2.1.2"))
        #expect(!developmentBuild.allowsUpdate(toVersion: "2.0.1"))
    }

    @Test("an Xcode build is not offered a published build of its own version")
    func developmentBuildRejectsSameVersion() {
        #expect(!developmentBuild.allowsUpdate(toVersion: "3.0.0"))
    }

    @Test("an Xcode build is offered a later version")
    func developmentBuildAcceptsLaterVersion() {
        #expect(developmentBuild.allowsUpdate(toVersion: "3.0.1"))
        #expect(developmentBuild.allowsUpdate(toVersion: "3.1"))
        #expect(developmentBuild.allowsUpdate(toVersion: "4.0.0"))
    }

    @Test("a numbered build is not offered an older version")
    func numberedBuildRejectsOlderVersion() {
        #expect(!numberedBuild.allowsUpdate(toVersion: "2.1.2"))
        #expect(!numberedBuild.allowsUpdate(toVersion: "2.10.0"))
    }

    @Test("a numbered build leaves builds of its own version to Sparkle's build comparison")
    func numberedBuildAcceptsSameVersion() {
        #expect(numberedBuild.allowsUpdate(toVersion: "3.0.0"))
        #expect(numberedBuild.allowsUpdate(toVersion: "3.0"))
    }

    @Test("a numbered build is offered a later version")
    func numberedBuildAcceptsLaterVersion() {
        #expect(numberedBuild.allowsUpdate(toVersion: "3.0.1"))
        #expect(numberedBuild.allowsUpdate(toVersion: "3.10.0"))
    }

    @Test("only build number 1 is a development build")
    func developmentBuildDetection() {
        #expect(developmentBuild.isDevelopmentBuild)
        #expect(!numberedBuild.isDevelopmentBuild)
    }
}

@Suite("UpdaterClient.lastCheckDisplay")
struct UpdaterClientLastCheckDisplayTests {
    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("a check made after the page's clock last ticked reads as now, not in the future")
    func checkAfterClockTick() {
        // The page's clock ticks every 30 seconds; a check finishing between ticks read "in 8 seconds".
        let display = UpdaterClient.lastCheckDisplay(for: now.addingTimeInterval(8), relativeTo: now, locale: locale)
        #expect(display == "now")
    }

    @Test("a check at the page's clock reads as now")
    func checkAtClock() {
        #expect(UpdaterClient.lastCheckDisplay(for: now, relativeTo: now, locale: locale) == "now")
    }

    @Test("an earlier check reads as past")
    func earlierCheck() {
        let display = UpdaterClient.lastCheckDisplay(for: now.addingTimeInterval(-120), relativeTo: now, locale: locale)
        #expect(display == "2 minutes ago")
    }

    @Test("no check reads as never")
    func noCheck() {
        #expect(UpdaterClient.lastCheckDisplay(for: nil, relativeTo: now, locale: locale) == "Never")
    }
}
