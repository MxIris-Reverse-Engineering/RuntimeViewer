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
}
