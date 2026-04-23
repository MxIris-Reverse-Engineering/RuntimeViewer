import Testing
import Foundation
@testable import RuntimeViewerSettings

@Suite("Settings.Update")
struct SettingsUpdateTests {
    @Test("allowedChannels is empty when prereleases are opted out")
    func allowedChannelsDefaultChannel() {
        var update = Settings.Update.default
        update.includePrereleases = false
        #expect(update.allowedChannels == [])
    }

    @Test("allowedChannels contains beta when prereleases are opted in")
    func allowedChannelsIncludesBeta() {
        var update = Settings.Update.default
        update.includePrereleases = true
        #expect(update.allowedChannels == ["beta"])
    }

    @Test("default has expected baseline values")
    func defaultSnapshot() {
        let update = Settings.Update.default
        #expect(update.automaticallyChecks == true)
        #expect(update.automaticallyDownloads == false)
        #expect(update.checkInterval == .daily)
        #expect(update.includePrereleases == false)
    }
}

@Suite("Settings.CheckInterval")
struct SettingsCheckIntervalTests {
    @Test("timeInterval matches Sparkle-expected seconds")
    func timeIntervalSeconds() {
        #expect(Settings.CheckInterval.hourly.timeInterval == 3_600)
        #expect(Settings.CheckInterval.daily.timeInterval == 86_400)
        #expect(Settings.CheckInterval.weekly.timeInterval == 604_800)
    }

    @Test("displayName is stable")
    func displayNames() {
        #expect(Settings.CheckInterval.hourly.displayName == "Hourly")
        #expect(Settings.CheckInterval.daily.displayName == "Daily")
        #expect(Settings.CheckInterval.weekly.displayName == "Weekly")
    }

    @Test("allCases covers every interval")
    func allCasesCoverage() {
        #expect(Settings.CheckInterval.allCases.count == 3)
        #expect(Set(Settings.CheckInterval.allCases) == [.hourly, .daily, .weekly])
    }
}
