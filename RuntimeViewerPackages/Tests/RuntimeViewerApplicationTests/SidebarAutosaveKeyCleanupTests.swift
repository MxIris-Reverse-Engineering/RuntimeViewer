#if os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerApplication
import RuntimeViewerCommunication

@Suite("SidebarAutosaveKeyCleanup")
struct SidebarAutosaveKeyCleanupTests {
    /// A throwaway suite name, so nothing here touches the app's own domain.
    private func withTemporaryUserDefaults<Result>(_ body: (UserDefaults) throws -> Result) rethrows -> Result {
        let suiteName = "SidebarAutosaveKeyCleanupTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        return try body(userDefaults)
    }

    @Test(
        "Only this project's autosave entries are matched",
        arguments: [
            ("NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.SpringBoard", true),
            ("NSTableView Columns com.JH.RuntimeViewer.SidebarRuntimeObjectViewController.autosaveName.My Mac", true),
            ("NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.v1:bonjour:client:DEV:SpringBoard", true),
            // Ours, but not an autosave entry.
            ("com.JH.RuntimeViewer.SidebarRootViewController.identifier.SpringBoard", false),
            // Someone else's autosave entry that happens to live in the same domain.
            ("NSTableView Columns com.apple.SomeOtherApp.autosaveName.Whatever", false),
            ("NSWindow Frame com.JH.RuntimeViewer.MainWindow", false),
            ("generationOptions", false),
            ("bookmarkScopeMigrationCompleted", false),
        ]
    )
    func matchesOnlyOwnedKeys(key: String, expected: Bool) {
        #expect(SidebarAutosaveKeyCleanup.matchesOwnedAutosaveKey(key) == expected)
    }

    @Test(
        "The app's other autosave entries survive",
        arguments: [
            // Window position. Ends at `.autosaveName` with nothing after it,
            // which is the *only* thing separating it from a sidebar key — one
            // character. Pinned here so that adding a suffix over there, which
            // would look harmless, fails this test instead of quietly wiping
            // the user's window frame and split widths on next launch.
            "com.JH.RuntimeViewer.MainWindowController.autosaveName",
            "NSWindow Frame com.JH.RuntimeViewer.MainWindowController.autosaveName",
            // Split view widths.
            "com.JH.RuntimeViewer.MainSplitViewController.autosaveName",
            "NSSplitView Subview Frames com.JH.RuntimeViewer.MainSplitViewController.autosaveName",
        ]
    )
    func otherAutosaveEntriesSurvive(key: String) {
        #expect(SidebarAutosaveKeyCleanup.matchesOwnedAutosaveKey(key) == false)
    }

    @Test("The sweep removes the stale entries and leaves everything else alone")
    func sweepRemovesOnlyOwnedKeys() {
        withTemporaryUserDefaults { userDefaults in
            userDefaults.set(["UIKit"], forKey: "NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.SpringBoard")
            userDefaults.set(["AppKit"], forKey: "NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.My Mac")
            userDefaults.set([:], forKey: "NSTableView Columns com.apple.SomeOtherApp.autosaveName.Whatever")
            userDefaults.set(42, forKey: "generationOptions")

            let removedCount = SidebarAutosaveKeyCleanup.removeOwnedAutosaveKeys(in: userDefaults)

            #expect(removedCount == 2)
            #expect(userDefaults.object(forKey: "NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.SpringBoard") == nil)
            #expect(userDefaults.object(forKey: "NSTableView Columns com.apple.SomeOtherApp.autosaveName.Whatever") != nil)
            #expect(userDefaults.integer(forKey: "generationOptions") == 42)
        }
    }

    @Test("The sweep runs once, and never again")
    func sweepRunsOnlyOnce() {
        withTemporaryUserDefaults { userDefaults in
            let flagKey = "cleanupCompleted"
            let staleKey = "NSOutlineView Items com.JH.RuntimeViewer.SidebarRootViewController.autosaveName.SpringBoard"
            userDefaults.set(["UIKit"], forKey: staleKey)

            SidebarAutosaveKeyCleanup.runIfNeeded(userDefaults: userDefaults, flagKey: flagKey)
            #expect(userDefaults.object(forKey: staleKey) == nil)
            #expect(userDefaults.bool(forKey: flagKey))

            // A peer on a legacy scope goes on writing under a display-name key.
            // Those are live state, not leftovers, and a second sweep would eat
            // them on every launch.
            userDefaults.set(["Foundation"], forKey: staleKey)
            SidebarAutosaveKeyCleanup.runIfNeeded(userDefaults: userDefaults, flagKey: flagKey)
            #expect(userDefaults.array(forKey: staleKey) as? [String] == ["Foundation"])
        }
    }
}

// MARK: - Sidebar key composition

@Suite("Sidebar autosave key composition")
struct SidebarAutosaveKeyCompositionTests {
    /// The sidebar builds its keys inline in the two view controllers, which
    /// live in the app target and cannot be reached from here. What *can* be
    /// pinned is the property those keys are built from, which is where the
    /// defect was.
    @Test("Two devices running a same-named process get different keys")
    func sameProcessOnTwoDevicesGetsDifferentKeys() throws {
        let first = try #require(RuntimeBookmarkScope.bonjour(
            deviceID: "11111111-2222-3333-4444-555555555555", processName: "SpringBoard", role: .client
        ))
        let second = try #require(RuntimeBookmarkScope.bonjour(
            deviceID: "99999999-8888-7777-6666-555555555555", processName: "SpringBoard", role: .client
        ))

        #expect(first.sidebarAutosaveKey != second.sidebarAutosaveKey)
        // Both used to be the bare display name, which is how they collided.
        #expect(first.sidebarAutosaveKey != "SpringBoard")
    }

    @Test("Two same-named processes on one device do share a key, on purpose")
    func sameProcessNameOnOneDeviceSharesAKey() throws {
        // Accepted cost, not a defect: the advertisement carries no bundle
        // identifier, so device plus process name is as fine-grained as the
        // identity gets. Pinned here so a future change has to be deliberate.
        let deviceIdentifier = "11111111-2222-3333-4444-555555555555"
        let first = try #require(RuntimeBookmarkScope.bonjour(deviceID: deviceIdentifier, processName: "SpringBoard", role: .client))
        let second = try #require(RuntimeBookmarkScope.bonjour(deviceID: deviceIdentifier, processName: "SpringBoard", role: .client))

        #expect(first.sidebarAutosaveKey == second.sidebarAutosaveKey)
    }

    @Test("A peer relaunching keeps its key")
    func relaunchKeepsItsKey() {
        let firstLaunch = RuntimeBookmarkScope.recovered(
            from: .bonjour(name: "SpringBoard", identifier: "11111111-2222-3333-4444-555555555555-100", role: .client)
        )
        let secondLaunch = RuntimeBookmarkScope.recovered(
            from: .bonjour(name: "SpringBoard", identifier: "11111111-2222-3333-4444-555555555555-200", role: .client)
        )
        #expect(firstLaunch?.sidebarAutosaveKey == secondLaunch?.sidebarAutosaveKey)
    }

    @Test("A legacy fallback key never carries the process identifier")
    func legacyFallbackKeyCarriesNoProcessIdentifier() {
        // The sidebar must fall back to the display name and not to
        // `source.identifier`. The identifier is the pid-bearing one, and
        // adopting it would give the peer a fresh key on every relaunch —
        // accumulating in UserDefaults forever, which is precisely the failure
        // this change removes.
        let source = RuntimeSource.bonjour(name: "SpringBoard", identifier: "11111111-2222-3333-4444-555555555555-4242", role: .client)
        let scope = RuntimeBookmarkScope.legacy(for: source)

        #expect(scope.sidebarAutosaveKey == "SpringBoard")
        #expect(!scope.sidebarAutosaveKey.contains("4242"))
    }
}

#endif
