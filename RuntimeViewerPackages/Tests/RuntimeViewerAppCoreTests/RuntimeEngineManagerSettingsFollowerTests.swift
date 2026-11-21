import Foundation
import Testing
import Dependencies
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerSettings
import RuntimeViewerAppTestingSupport

/// The part of the settings lifecycle both apps share (proposal
/// `window-model-on-ios`): Settings › Developer's shared cache switch goes into
/// the engine manager, at once and on every change after.
@Suite("Following the settings the engine manager takes")
@MainActor
struct RuntimeEngineManagerSettingsFollowerTests {
    @Test("writes the shared cache switch into the manager, and every change after")
    func followsTheSharedCacheSwitch() async throws {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        let settings = SettingsAccess.preview
        settings.developer.isEnabled = true
        settings.developer.sharesSharedCacheImages = false
        let follower = withDependencies {
            $0.runtimeEngineManager = manager
            $0.settings = settings
        } operation: {
            RuntimeEngineManagerSettingsFollower()
        }

        follower.startFollowing()
        #expect(!manager.sharesSharedCacheImages, "the stored value was not written at once")

        settings.developer.sharesSharedCacheImages = true
        #expect(await pollUntil(timeout: .seconds(5)) { manager.sharesSharedCacheImages }, "a change to the switch was not followed")

        settings.developer.sharesSharedCacheImages = false
        #expect(await pollUntil(timeout: .seconds(5)) { !manager.sharesSharedCacheImages }, "turning the switch off again was not followed")

        settings.developer.isEnabled = false
        #expect(await pollUntil(timeout: .seconds(5)) { manager.sharesSharedCacheImages }, "with Developer off the manager should share, whatever the switch says")
    }
}
