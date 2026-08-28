import Foundation
import FoundationToolbox

/// Removes the sidebar's `NSOutlineView` autosave entries left behind when the
/// keys moved from the peer's display name to its `RuntimeBookmarkScope`.
///
/// The expansion state itself is deliberately not migrated: it is cheap,
/// regenerable UI state, and one re-expansion brings it back. What is not
/// acceptable is leaving the old entries in `UserDefaults` forever — nothing
/// will ever read them again, and unbounded accumulation of dead persistence
/// keys is the same defect this work removes from the bookmark file.
///
/// Runs once, gated on its own flag. It has to be more than a no-op after the
/// first launch, because a peer that falls back to a legacy scope keeps writing
/// under a display-name key — those are current, not stale, and re-running the
/// sweep would delete live state every launch.
@Loggable(.private)
enum SidebarAutosaveKeyCleanup {
    /// Both halves of a *sidebar* autosave entry.
    ///
    /// Matching on both is what keeps the sweep off other software's keys.
    /// AppKit wraps the name we choose — `NSTableView Columns <name>` for
    /// column layout, `NSOutlineView Items <name>` for expansion — so the
    /// stored key is not one this project fully controls, and a prefix test
    /// would miss every one of them.
    ///
    /// The **trailing dot** on the second marker is what excludes the app's
    /// other autosave entries, whose names stop at `.autosaveName` with nothing
    /// after it: the main window's frame and the split view's widths. That is a
    /// one-character distinction, so `SidebarAutosaveKeyCleanupTests` pins
    /// those two keys as survivors — give either a suffix and the test fails
    /// rather than the user's window position disappearing.
    private static let ownedKeyMarkers = ["com.JH.RuntimeViewer.", ".autosaveName."]

    static func matchesOwnedAutosaveKey(_ key: String) -> Bool {
        ownedKeyMarkers.allSatisfy(key.contains)
    }

    /// Deletes every owned autosave entry from `userDefaults` and answers how
    /// many went.
    @discardableResult
    static func removeOwnedAutosaveKeys(in userDefaults: UserDefaults) -> Int {
        let staleKeys = userDefaults.dictionaryRepresentation().keys.filter(matchesOwnedAutosaveKey)
        for key in staleKeys {
            userDefaults.removeObject(forKey: key)
        }
        return staleKeys.count
    }

    static func runIfNeeded(userDefaults: UserDefaults = .standard, flagKey: String) {
        guard !userDefaults.bool(forKey: flagKey) else { return }
        defer { userDefaults.set(true, forKey: flagKey) }

        let removedCount = removeOwnedAutosaveKeys(in: userDefaults)
        #log(.info, "Sidebar autosave cleanup: removed \(removedCount, privacy: .public) stale display-name keyed entr\(removedCount == 1 ? "y" : "ies")")
    }
}
