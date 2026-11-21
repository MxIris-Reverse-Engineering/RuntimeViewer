#if os(macOS)

import Testing
@testable import RuntimeViewerAppCore

/// When the macOS app shows its Welcome window instead of opening a window on My Mac: at launch, once
/// the settings are read, and when the Dock icon is clicked with no window open.
@Suite("Welcome window policy")
struct WelcomeWindowPolicyTests {
    @Test("an untitled-document request that comes before the settings are read waits for them")
    func untitledRequestBeforeSettingsLoadWaits() {
        #expect(WelcomeWindowPolicy.decisionForUntitledDocumentRequest(areSettingsLoaded: false, showsWelcomeWindow: true) == .waitForSettings)
        #expect(WelcomeWindowPolicy.decisionForUntitledDocumentRequest(areSettingsLoaded: false, showsWelcomeWindow: false) == .waitForSettings)
    }

    @Test("an untitled-document request shows the Welcome window when the setting is on")
    func untitledRequestShowsWelcomeWindowWhenEnabled() {
        #expect(WelcomeWindowPolicy.decisionForUntitledDocumentRequest(areSettingsLoaded: true, showsWelcomeWindow: true) == .showWelcomeWindow)
    }

    @Test("an untitled-document request opens a window on My Mac when the setting is off")
    func untitledRequestOpensUntitledDocumentWhenDisabled() {
        #expect(WelcomeWindowPolicy.decisionForUntitledDocumentRequest(areSettingsLoaded: true, showsWelcomeWindow: false) == .openUntitledDocument)
    }

    @Test("a held launch request does nothing once a document window is up")
    func heldLaunchRequestDoesNothingOnceADocumentWindowIsUp() {
        #expect(WelcomeWindowPolicy.decisionAfterSettingsLoaded(showsWelcomeWindow: true, hasDocumentWindow: true) == nil)
        #expect(WelcomeWindowPolicy.decisionAfterSettingsLoaded(showsWelcomeWindow: false, hasDocumentWindow: true) == nil)
    }

    @Test("a held launch request follows the setting it reads once loaded")
    func heldLaunchRequestFollowsTheLoadedSetting() {
        #expect(WelcomeWindowPolicy.decisionAfterSettingsLoaded(showsWelcomeWindow: true, hasDocumentWindow: false) == .showWelcomeWindow)
        #expect(WelcomeWindowPolicy.decisionAfterSettingsLoaded(showsWelcomeWindow: false, hasDocumentWindow: false) == .openUntitledDocument)
    }

    @Test("a Dock click with no window to bring back follows the setting")
    func reopenFollowsTheSetting() {
        #expect(WelcomeWindowPolicy.decisionForReopen(showsWelcomeWindow: true) == .showWelcomeWindow)
        #expect(WelcomeWindowPolicy.decisionForReopen(showsWelcomeWindow: false) == .openUntitledDocument)
    }
}

#endif
