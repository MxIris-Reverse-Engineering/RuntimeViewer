#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// The engine manager gives My Mac and the Mac Catalyst engine each other as
/// owners as they come up, and takes the owners away when sharing is turned
/// off. The Mac Catalyst launch is stood in for with an engine that is never
/// connected; My Mac is `RuntimeEngine.local`, in process here.
@Suite("Shared cache owners wiring", .serialized)
@MainActor
struct SharedCacheOwnersWiringTests {
    @Test("My Mac and Mac Catalyst borrow from each other, until sharing is turned off")
    func systemEnginesBorrowFromEachOther() async throws {
        let macCatalystEngine = RuntimeEngine(source: .macCatalystClient, engineID: "shared-cache-owners-wiring.catalyst.\(UUID().uuidString)")
        let manager = RuntimeEngineManager(
            configuration: .application,
            startupHandler: { _ in },
            macCatalystLaunching: .init(makeConnectedEngine: { macCatalystEngine }, helperApplication: nil)
        )

        await manager.launchSystemRuntimeEngines()
        await manager.waitForMacCatalystLaunch()
        await manager.waitForSharedCacheOwnersUpdate()

        let localOwners = try #require(RuntimeEngine.local.sharedCacheOwners)
        #expect(localOwners.macOS === RuntimeEngine.local)
        #expect(localOwners.macCatalyst === macCatalystEngine)
        #expect(macCatalystEngine.sharedCacheOwners == localOwners)

        manager.sharesSharedCacheImages = false
        await manager.waitForSharedCacheOwnersUpdate()

        #expect(RuntimeEngine.local.sharedCacheOwners == nil)
        #expect(macCatalystEngine.sharedCacheOwners == nil)
    }
}

#endif
