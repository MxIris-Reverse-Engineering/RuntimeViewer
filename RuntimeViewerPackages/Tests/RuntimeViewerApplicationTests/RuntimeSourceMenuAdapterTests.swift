import AppKit
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// `RuntimeSourceMenuAdapter`: the classic toolbar's runtime source pop-up, the `NSPopUpButton` with
/// the menu RuntimeViewer had before its toolbar followed Xcode (proposal
/// `draft-xcode-style-runtime-source-picker`). A choice is made the way the pop-up makes it, by
/// sending the chosen item's action to its target: a `swift test` process has no `NSApp` to send it
/// through.
@Suite("RuntimeSourceMenuAdapter")
@MainActor
struct RuntimeSourceMenuAdapterTests {
    private static let content = RuntimeSourcePickerContent(sections: [
        RuntimeSourcePickerContent.Section(title: "JH's Mac Studio", sources: [
            RuntimeSourcePickerContent.Source(engineIdentifier: "local", title: "My Mac", image: NSImage(size: NSSize(width: 32, height: 32)), isCurrent: true),
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

    private static func makeAdapter(content: RuntimeSourcePickerContent = content) -> RuntimeSourceMenuAdapter {
        let adapter = RuntimeSourceMenuAdapter(popUpButton: NSPopUpButton())
        adapter.content = content
        return adapter
    }

    /// The menu as text: `#` before a header, `—` for a separator.
    private static func layout(of menu: NSMenu?) -> [String] {
        (menu?.items ?? []).map { item in
            if item.isSeparatorItem { return "—" }
            if item.isSectionHeader { return "# " + item.title }
            return item.title
        }
    }

    private static func item(titled title: String, in menu: NSMenu?) throws -> NSMenuItem {
        try #require(menu?.items.first { $0.title == title })
    }

    /// Chooses `item` as the pop-up does: the pop-up selects an item of its own menu, then sends the
    /// item's action to the item's target.
    private static func choose(_ item: NSMenuItem, in popUpButton: NSPopUpButton) throws {
        if item.menu === popUpButton.menu {
            popUpButton.select(item)
        }
        let action = try #require(item.action)
        let target = try #require(item.target as? NSObject)
        target.perform(action, with: item)
    }

    @Test("lists a header per host with its sources under it, the window's source selected, Open File… below")
    func listsHostsAndTheirSources() throws {
        let adapter = Self.makeAdapter()

        #expect(Self.layout(of: adapter.popUpButton.menu) == [
            "# JH's Mac Studio", "My Mac", "My Mac (Mac Catalyst)", "—", "# iPhone", "SpringBoard", "—", "Open File…",
        ])
        #expect(adapter.popUpButton.titleOfSelectedItem == "My Mac")
        let myMac = try Self.item(titled: "My Mac", in: adapter.popUpButton.menu)
        let iconSize = NSSize(width: 20, height: 20)
        #expect(myMac.image?.size == iconSize)
        #expect(myMac.isEnabled)
    }

    @Test("the menu sizes copies of the icons, leaving the list's own images alone")
    func iconsAreSizedOnCopies() throws {
        let image = try #require(Self.content.sections.first?.sources.first?.image)
        let adapter = Self.makeAdapter()

        let myMac = try Self.item(titled: "My Mac", in: adapter.popUpButton.menu)
        let originalSize = NSSize(width: 32, height: 32)
        #expect(myMac.image !== image)
        #expect(image.size == originalSize)
    }

    @Test("while its engine is gone, the window's source leads the menu, dimmed and selected")
    func disconnectedSourceLeadsTheMenu() throws {
        let content = RuntimeSourcePickerContent(
            disconnectedSource: RuntimeSourcePickerContent.Source(engineIdentifier: "gone", title: "iPad (Disconnected)", image: nil, isCurrent: true, isEnabled: false),
            sections: [
                RuntimeSourcePickerContent.Section(title: "JH's Mac Studio", sources: [
                    RuntimeSourcePickerContent.Source(engineIdentifier: "local", title: "My Mac", image: nil, isCurrent: false),
                ]),
            ]
        )
        let adapter = Self.makeAdapter(content: content)

        #expect(Self.layout(of: adapter.popUpButton.menu) == ["iPad (Disconnected)", "—", "# JH's Mac Studio", "My Mac", "—", "Open File…"])
        let disconnectedItem = try Self.item(titled: "iPad (Disconnected)", in: adapter.popUpButton.menu)
        #expect(disconnectedItem.isEnabled == false)
        #expect(adapter.row(for: disconnectedItem) == nil)
        #expect(adapter.popUpButton.titleOfSelectedItem == "iPad (Disconnected)")
    }

    @Test("an offline file that can be paired adds a Dependency Cache submenu: the caches, the one in use checked, then Manage in Settings…")
    func dependencyCacheSubmenu() throws {
        let adapter = Self.makeAdapter(content: RuntimeSourcePickerContent(sections: Self.content.sections, dependencyCacheChoices: Self.dependencyCacheChoices))
        let menu = adapter.popUpButton.menu

        let dependencyCacheItem = try Self.item(titled: "Dependency Cache", in: menu)
        let submenu = try #require(dependencyCacheItem.submenu)
        #expect(menu?.items.last === dependencyCacheItem)
        #expect(Self.layout(of: submenu) == ["This Mac's Dyld Shared Cache", "None", "—", "Manage in Settings…"])
        #expect(submenu.items.prefix(2).map(\.state) == [.on, .off])
    }

    @Test("without caches to choose from there is no Dependency Cache item")
    func noDependencyCacheWithoutChoices() {
        let adapter = Self.makeAdapter()

        #expect(adapter.popUpButton.menu?.items.contains { $0.title == "Dependency Cache" } == false)
    }

    @Test("choosing a source reports its engine, and the pop-up shows it until the window follows")
    func choosingASourceReportsIt() throws {
        let adapter = Self.makeAdapter()
        var chosenSources: [String] = []
        let subscription = adapter.sourceSelected.emitOnNext { chosenSources.append($0) }
        defer { subscription.dispose() }

        try Self.choose(Self.item(titled: "SpringBoard", in: adapter.popUpButton.menu), in: adapter.popUpButton)

        #expect(chosenSources == ["springboard"])
        #expect(adapter.popUpButton.titleOfSelectedItem == "SpringBoard")
    }

    @Test("a command is reported, and the pop-up goes back to the window's source")
    func commandsAreReportedAndTheSourceStaysSelected() throws {
        let adapter = Self.makeAdapter(content: RuntimeSourcePickerContent(sections: Self.content.sections, dependencyCacheChoices: Self.dependencyCacheChoices))
        var openFileRequests = 0
        var chosenCaches: [RuntimeOfflineFile.DependencyCache?] = []
        var settingsRequests = 0
        let subscriptions = [
            adapter.openFileRequested.emitOnNext { openFileRequests += 1 },
            adapter.dependencyCacheSelected.emitOnNext { chosenCaches.append($0) },
            adapter.dependencyCacheSettingsRequested.emitOnNext { settingsRequests += 1 },
        ]
        defer { subscriptions.forEach { $0.dispose() } }
        let menu = adapter.popUpButton.menu
        let submenu = try #require(try Self.item(titled: "Dependency Cache", in: menu).submenu)

        try Self.choose(Self.item(titled: "Open File…", in: menu), in: adapter.popUpButton)
        let selectedAfterOpenFile = adapter.popUpButton.titleOfSelectedItem
        try Self.choose(Self.item(titled: "None", in: submenu), in: adapter.popUpButton)
        try Self.choose(Self.item(titled: "Manage in Settings…", in: submenu), in: adapter.popUpButton)

        #expect(openFileRequests == 1)
        #expect(chosenCaches == [nil])
        #expect(settingsRequests == 1)
        #expect(selectedAfterOpenFile == "My Mac")
        #expect(adapter.popUpButton.titleOfSelectedItem == "My Mac")
    }

    @Test("new content rebuilds the menu and selects the window's new source")
    func newContentRebuildsTheMenu() {
        let adapter = Self.makeAdapter()
        adapter.content = RuntimeSourcePickerContent(sections: [
            RuntimeSourcePickerContent.Section(title: "JH's Mac Studio", sources: [
                RuntimeSourcePickerContent.Source(engineIdentifier: "local", title: "My Mac", image: nil, isCurrent: false),
                RuntimeSourcePickerContent.Source(engineIdentifier: "catalyst", title: "My Mac (Mac Catalyst)", image: nil, isCurrent: true),
            ]),
        ])

        #expect(Self.layout(of: adapter.popUpButton.menu) == ["# JH's Mac Studio", "My Mac", "My Mac (Mac Catalyst)", "—", "Open File…"])
        #expect(adapter.popUpButton.titleOfSelectedItem == "My Mac (Mac Catalyst)")
    }
}
