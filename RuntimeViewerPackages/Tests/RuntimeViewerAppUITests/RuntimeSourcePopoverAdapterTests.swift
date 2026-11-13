import AppKit
import AppKitPlus
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI
@testable import RuntimeViewerUI

/// `RuntimeSourcePopoverAdapter`: the runtime source picker's popover on AppKitPlus's
/// `NSNavigationPopoverController` — proposal `0070-xcode-style-runtime-source-picker`, spec in
/// `/Volumes/RE/Xcode/27.2-27B52/README.md`, "The scheme picker's popover". The controller is a real
/// one that is never shown: a popover cannot open in a test, so the user's choices and typing reach
/// the adapter the way the controller hands them to its delegate.
@Suite("RuntimeSourcePopoverAdapter")
@MainActor
struct RuntimeSourcePopoverAdapterTests {
    private static let content = RuntimeSourcePickerContent(sections: [
        RuntimeSourcePickerContent.Section(title: "JH's Mac Studio", sources: [
            RuntimeSourcePickerContent.Source(engineIdentifier: "local", title: "My Mac", image: nil, isCurrent: true),
            RuntimeSourcePickerContent.Source(engineIdentifier: "catalyst", title: "My Mac (Mac Catalyst)", image: nil, isCurrent: false),
        ]),
        RuntimeSourcePickerContent.Section(title: "iPhone", sources: [
            RuntimeSourcePickerContent.Source(engineIdentifier: "springboard", title: "SpringBoard", image: nil, isCurrent: false),
        ]),
    ])

    private static let dependencyCacheChoices = [
        RuntimeSourcePickerContent.DependencyCacheChoice(title: "This Mac's Dyld Shared Cache", dependencyCache: .systemDyldSharedCache, isCurrent: true),
        RuntimeSourcePickerContent.DependencyCacheChoice(title: "None", dependencyCache: nil, isCurrent: false),
    ]

    private static func makeAdapter(content: RuntimeSourcePickerContent = content) -> RuntimeSourcePopoverAdapter {
        let adapter = RuntimeSourcePopoverAdapter()
        adapter.content = content
        return adapter
    }

    @Test("lists a header per host with its sources under it, the window's source checked, Open File… below, set up as Xcode's")
    func listsHostsAndTheirSources() throws {
        let adapter = Self.makeAdapter()
        let controller = adapter.makePopoverController()

        #expect(controller.items.map(\.title) == ["JH's Mac Studio", "My Mac", "My Mac (Mac Catalyst)", "iPhone", "SpringBoard"])
        #expect(controller.footerItems.map(\.title) == ["Open File…"])
        #expect(controller.items.filter { adapter.cellView(for: $0)?.isChecked == true }.map(\.title) == ["My Mac"])
        #expect(adapter.cellView(for: try #require(controller.items.first)) == nil)
        #expect(adapter.cellView(for: try #require(controller.footerItems.first)) == nil)
        #expect(controller.usesFilterIcon)
        #expect(controller.hierarchyStyle == .pushNavigation)
        #expect(controller.resizingBehavior == [.grows, .shrinks, .keepsTopStable, .preservesWidthWhenChangingItemGroup])
        #expect(controller.delegate === adapter)
    }

    @Test("while its engine is gone, the window's source leads the list, checked and not a choice")
    func disconnectedSourceLeadsTheList() throws {
        var content = Self.content
        content.disconnectedSource = RuntimeSourcePickerContent.Source(
            engineIdentifier: "gone",
            title: "SpringBoard (Disconnected)",
            image: nil,
            isCurrent: true,
            isEnabled: false
        )
        let adapter = Self.makeAdapter(content: content)
        let controller = adapter.makePopoverController()

        let disconnectedItem = try #require(controller.items.first)
        let disconnectedCell = try #require(adapter.cellView(for: disconnectedItem))
        #expect(disconnectedItem.title == "SpringBoard (Disconnected)")
        #expect(disconnectedItem.isEnabled == false)
        #expect(disconnectedCell.isChecked)
        #expect(disconnectedCell.isEnabled == false)
        #expect(controller.items.dropFirst().first?.title == "JH's Mac Studio")
    }

    @Test("an offline file that can be paired adds Dependency Cache below, which pushes the caches and Manage in Settings…")
    func dependencyCachePushesTheCaches() throws {
        var content = Self.content
        content.dependencyCacheChoices = Self.dependencyCacheChoices
        let adapter = Self.makeAdapter(content: content)
        let controller = adapter.makePopoverController()

        #expect(controller.footerItems.map(\.title) == ["Open File…", "Dependency Cache"])
        let dependencyCacheItem = try #require(controller.footerItems.last)
        #expect(dependencyCacheItem.style == .group)

        let closes = adapter.navigationPopoverController(controller, didSelect: dependencyCacheItem)

        #expect(closes == false)
        #expect(controller.items.map(\.title) == ["This Mac's Dyld Shared Cache", "None"])
        #expect(controller.footerItems.map(\.title) == ["Manage in Settings…"])
        #expect(controller.items.map { adapter.cellView(for: $0)?.isChecked } == [true, false])
    }

    @Test("a choice is reported once the popover closed: a source, Open File…, a cache, Manage in Settings…")
    func choicesAreReportedOnClose() throws {
        var content = Self.content
        content.dependencyCacheChoices = Self.dependencyCacheChoices
        let adapter = Self.makeAdapter(content: content)
        var chosenSources: [String] = []
        var openFileRequests = 0
        var chosenCaches: [RuntimeOfflineFile.DependencyCache?] = []
        var settingsRequests = 0
        let subscriptions = [
            adapter.sourceSelected.emitOnNext { chosenSources.append($0) },
            adapter.openFileRequested.emitOnNext { openFileRequests += 1 },
            adapter.dependencyCacheSelected.emitOnNext { chosenCaches.append($0) },
            adapter.dependencyCacheSettingsRequested.emitOnNext { settingsRequests += 1 },
        ]
        defer { subscriptions.forEach { $0.dispose() } }

        let sourceController = adapter.makePopoverController()
        let catalystItem = try #require(sourceController.items.first { $0.title == "My Mac (Mac Catalyst)" })
        let closesForSource = adapter.navigationPopoverController(sourceController, didSelect: catalystItem)
        let reportedBeforeClosing = chosenSources
        adapter.navigationPopoverController(sourceController, didCloseWithSelectedItem: catalystItem)

        let openFileController = adapter.makePopoverController()
        adapter.navigationPopoverController(openFileController, didCloseWithSelectedItem: try #require(openFileController.footerItems.first))

        let cacheController = adapter.makePopoverController()
        _ = adapter.navigationPopoverController(cacheController, didSelect: try #require(cacheController.footerItems.last))
        adapter.navigationPopoverController(cacheController, didCloseWithSelectedItem: try #require(cacheController.items.last))

        let settingsController = adapter.makePopoverController()
        _ = adapter.navigationPopoverController(settingsController, didSelect: try #require(settingsController.footerItems.last))
        adapter.navigationPopoverController(settingsController, didCloseWithSelectedItem: try #require(settingsController.footerItems.first))

        let dismissedController = adapter.makePopoverController()
        adapter.navigationPopoverController(dismissedController, didCloseWithSelectedItem: nil)

        #expect(closesForSource)
        #expect(reportedBeforeClosing.isEmpty)
        #expect(chosenSources == ["catalyst"])
        #expect(openFileRequests == 1)
        #expect(chosenCaches == [nil])
        #expect(settingsRequests == 1)
    }

    @Test("the close of a popover that is no longer the adapter's reports nothing")
    func staleCloseReportsNothing() throws {
        let adapter = Self.makeAdapter()
        var chosenSources: [String] = []
        let subscription = adapter.sourceSelected.emitOnNext { chosenSources.append($0) }
        defer { subscription.dispose() }

        let staleController = adapter.makePopoverController()
        let staleItem = try #require(staleController.items.last)
        _ = adapter.makePopoverController()
        adapter.navigationPopoverController(staleController, didCloseWithSelectedItem: staleItem)

        #expect(chosenSources.isEmpty)
    }

    @Test("filtering keeps the matching sources under their hosts, drops a host left without any, and marks the match")
    func filteringKeepsMatchesUnderTheirHosts() throws {
        let adapter = Self.makeAdapter()
        let controller = adapter.makePopoverController()
        let myMacItem = try #require(controller.items.first { $0.title == "My Mac" })
        let springBoardItem = try #require(controller.items.first { $0.title == "SpringBoard" })

        adapter.navigationPopoverController(controller, filterStringDidChange: "mac")
        let filteredTitles = controller.filteredItems?.map(\.title)
        let matchRanges = adapter.cellView(for: myMacItem)?.filterMatchRanges
        let springBoardRanges = adapter.cellView(for: springBoardItem)?.filterMatchRanges
        adapter.navigationPopoverController(controller, filterStringDidChange: "")

        #expect(filteredTitles == ["JH's Mac Studio", "My Mac", "My Mac (Mac Catalyst)"])
        #expect(matchRanges == [NSRange(location: 3, length: 3)])
        #expect(springBoardRanges == [])
        #expect(adapter.cellView(for: myMacItem)?.filterMatchRanges == [])
    }

    @Test("while the cache level shows, the filter works on the caches")
    func filteringTheCacheLevel() throws {
        var content = Self.content
        content.dependencyCacheChoices = Self.dependencyCacheChoices
        let adapter = Self.makeAdapter(content: content)
        let controller = adapter.makePopoverController()
        _ = adapter.navigationPopoverController(controller, didSelect: try #require(controller.footerItems.last))

        adapter.navigationPopoverController(controller, filterStringDidChange: "none")

        #expect(controller.filteredItems?.map(\.title) == ["None"])
    }

    /// Turkish pairs I with ı and İ with i, so matching by the user's language would make `uiview` miss
    /// `UIView`. The language is changed in a process of its own, before anything there has read it; the
    /// exit status says what happened: 1 is the miss, 2 a language that did not change.
    @Test("matching ignores case the same way whatever the user's language")
    func matchingDoesNotFollowTheUsersLanguage() async {
        await #expect(processExitsWith: .success) {
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": ["tr-TR"], "AppleLocale": "tr_TR"], forName: UserDefaults.argumentDomain)
            guard Locale.current.language.languageCode?.identifier == "tr" else { exit(2) }
            let matchedRange = RuntimeSourcePopoverAdapter.matchedRange(of: "uiview", in: "UIViewService")
            exit(matchedRange == NSRange(location: 0, length: 6) ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    @Test("the content is as wide as the widest title, plus 36 for a row with a checkmark, and at most 366")
    func contentWidthFollowsXcode() {
        let adapter = Self.makeAdapter()
        let controller = adapter.makePopoverController()
        let sizingLabel = NSTextField(labelWithString: "My Mac (Mac Catalyst)")
        sizingLabel.font = .systemFont(ofSize: NSFont.systemFontSize)

        let width = adapter.navigationPopoverController(controller, widthFor: controller.items + controller.footerItems)

        #expect(width == sizingLabel.fittingSize.width + 36)

        let longContent = RuntimeSourcePickerContent(sections: [
            RuntimeSourcePickerContent.Section(title: "Host", sources: [
                RuntimeSourcePickerContent.Source(engineIdentifier: "long", title: String(repeating: "W", count: 80), image: nil, isCurrent: false),
            ]),
        ])
        let longAdapter = Self.makeAdapter(content: longContent)
        let longController = longAdapter.makePopoverController()
        #expect(longAdapter.navigationPopoverController(longController, widthFor: longController.items) == 366)
    }
}
