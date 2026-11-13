import Foundation
import RuntimeViewerCore

/// One tab of an editor pane.
///
/// A tab shows one object at a time and remembers what it has shown, so the toolbar's back and
/// forward walk this tab's own history, as in each tab of an Xcode editor pane. An empty tab, one
/// that has shown nothing, shows the content placeholder.
///
/// `id` is a stable identity that survives everything the tab shows, so the tab bar (and
/// DifferenceKit) track a tab across navigation rather than taking every new object for a new tab,
/// and routes name the tab they act on rather than its position, which another route can change.
public struct DocumentTab: Hashable, Identifiable, Sendable {
    /// Stable identity of a tab, kept apart from a pane's so that one is never passed for the other.
    public struct ID: Hashable, Sendable {
        private let rawValue: UUID

        init() {
            self.rawValue = UUID()
        }
    }

    public let id: ID

    public internal(set) var history: NavigationHistory

    /// An empty tab, unless given a history.
    init(id: ID = ID(), history: NavigationHistory = NavigationHistory()) {
        self.id = id
        self.history = history
    }

    /// The step on screen, or `nil` for an empty tab.
    public var currentEntry: NavigationEntry? {
        history.currentEntry
    }

    /// The object on screen, or `nil` for an empty tab and for a tab showing an image.
    public var object: RuntimeObject? {
        history.currentEntry?.object
    }

    /// The language the object on screen is shown in: `nil` for its own, `.swift` for an
    /// Objective-C object shown as Swift imports it.
    public var interfaceLanguage: RuntimeInterfaceLanguage? {
        history.currentEntry?.interfaceLanguage
    }

    /// The path of the image on screen while the tab shows an image rather than one of its objects
    /// (proposal `editor-jump-bar`); `nil` otherwise.
    public var imagePath: String? {
        history.currentEntry?.imagePath
    }

    /// Title shown on the tab: what is on screen, or a neutral label for an empty tab.
    public var title: String {
        history.currentEntry?.displayName ?? "New Tab"
    }
}
