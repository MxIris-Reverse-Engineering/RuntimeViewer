import Testing

@testable import RuntimeViewerSettings

@Suite("Developer settings")
struct DeveloperSettingsTests {
    @Test("the content loading delay takes effect only while developer options are on")
    func contentLoadingDelayFollowsMasterSwitch() {
        var developer = Settings.Developer()
        developer.contentLoadingDelay = 2
        #expect(developer.effectiveContentLoadingDelay == 0)

        developer.isEnabled = true
        #expect(developer.effectiveContentLoadingDelay == 2)
    }

    @Test("the engines share the shared cache images unless developer options turn it off")
    func sharingFollowsMasterSwitch() {
        var developer = Settings.Developer()
        #expect(developer.sharesSharedCacheImages, "sharing is off by default")
        developer.sharesSharedCacheImages = false
        #expect(developer.effectiveSharesSharedCacheImages, "a switch turned off while developer options are off took effect")

        developer.isEnabled = true
        #expect(!developer.effectiveSharesSharedCacheImages)
    }
}
