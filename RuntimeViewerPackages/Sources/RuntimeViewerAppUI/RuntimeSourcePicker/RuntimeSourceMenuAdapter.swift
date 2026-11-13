#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerAppCore
import RuntimeViewerArchitectures
import RuntimeViewerCore

/// Fills the classic toolbar's runtime source pop-up button — the `NSPopUpButton` RuntimeViewer had
/// before its toolbar followed Xcode — from the same `RuntimeSourcePickerContent` the picker's popover
/// lists, and reports what the user chose with the same signals as `RuntimeSourcePopoverAdapter`. Kept
/// out of the window controller so that it can be tested.
///
/// The menu is the one the pop-up had: a section header per host with its sources under it, each with
/// its icon, the source the window is on selected; while that source's engine is gone, a dimmed item
/// for it on top, selected. Below the sources sit Open File… and — while the window is on an offline
/// file that can be paired with a dependency cache — a Dependency Cache submenu listing the caches, the
/// one in use checked, with Manage in Settings… below them. A command is no source to show, so after
/// one the pop-up shows the window's source again.
@MainActor
public final class RuntimeSourceMenuAdapter: NSObject {
    /// The size the menu draws its icons at, as the pop-up always did.
    static let iconSize = NSSize(width: 20, height: 20)

    /// What one of the menu's items stands for.
    enum Row: Equatable {
        case source(engineIdentifier: String)
        case openFile
        case dependencyCacheChoice(RuntimeOfflineFile.DependencyCache?)
        case manageDependencyCaches
    }

    public let popUpButton: NSPopUpButton

    /// What the menu lists; the menu is rebuilt when it changes.
    public var content: RuntimeSourcePickerContent = .empty {
        didSet {
            guard content != oldValue else { return }
            rebuildMenu()
        }
    }

    private let sourceSelectedRelay = PublishRelay<String>()

    private let openFileRequestedRelay = PublishRelay<Void>()

    private let dependencyCacheSelectedRelay = PublishRelay<RuntimeOfflineFile.DependencyCache?>()

    private let dependencyCacheSettingsRequestedRelay = PublishRelay<Void>()

    /// The engine identifier of the source the user chose.
    public var sourceSelected: Signal<String> {
        sourceSelectedRelay.asSignal()
    }

    /// Open File… was chosen.
    public var openFileRequested: Signal<Void> {
        openFileRequestedRelay.asSignal()
    }

    /// The dependency cache chosen for the window's offline file; `nil` reads the file alone.
    public var dependencyCacheSelected: Signal<RuntimeOfflineFile.DependencyCache?> {
        dependencyCacheSelectedRelay.asSignal()
    }

    /// Manage in Settings… was chosen.
    public var dependencyCacheSettingsRequested: Signal<Void> {
        dependencyCacheSettingsRequestedRelay.asSignal()
    }

    /// What each item of the current menu stands for.
    private var rowsByItem: [ObjectIdentifier: Row] = [:]

    /// The item showing the window's source: the dimmed one while its engine is gone.
    private(set) weak var currentSourceItem: NSMenuItem?

    public init(popUpButton: NSPopUpButton) {
        self.popUpButton = popUpButton
        super.init()
        // Every item says itself whether it can be chosen: the dimmed source must stay dimmed.
        popUpButton.autoenablesItems = false
        rebuildMenu()
    }

    /// What `item` stands for, or `nil` for a header, a separator, the dimmed source or the submenu's
    /// own item.
    func row(for item: NSMenuItem) -> Row? {
        rowsByItem[ObjectIdentifier(item)]
    }

    private func rebuildMenu() {
        rowsByItem = [:]
        currentSourceItem = nil
        let menu = popUpButton.menu ?? NSMenu()
        menu.removeAllItems()
        if let disconnectedSource = content.disconnectedSource {
            let item = makeSourceItem(for: disconnectedSource)
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
            currentSourceItem = item
        }
        for (sectionIndex, section) in content.sections.enumerated() {
            if sectionIndex > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(.sectionHeader(title: section.title))
            for source in section.sources {
                let item = makeSourceItem(for: source)
                item.isEnabled = source.isEnabled
                addChoice(item, standingFor: .source(engineIdentifier: source.engineIdentifier))
                menu.addItem(item)
                if source.isCurrent, currentSourceItem == nil {
                    currentSourceItem = item
                }
            }
        }
        if !content.sections.isEmpty {
            menu.addItem(.separator())
        }
        let openFileItem = NSMenuItem(title: RuntimeSourcePopoverAdapter.openFileTitle, action: nil, keyEquivalent: "")
        addChoice(openFileItem, standingFor: .openFile)
        menu.addItem(openFileItem)
        if !content.dependencyCacheChoices.isEmpty {
            menu.addItem(makeDependencyCacheItem())
        }
        popUpButton.menu = menu
        popUpButton.select(currentSourceItem)
    }

    private func makeSourceItem(for source: RuntimeSourcePickerContent.Source) -> NSMenuItem {
        let item = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
        // A copy, so that sizing it for the menu leaves the popover's rows alone.
        if let image = source.image?.copy() as? NSImage {
            image.size = Self.iconSize
            item.image = image
        }
        return item
    }

    private func makeDependencyCacheItem() -> NSMenuItem {
        let submenu = NSMenu(title: RuntimeSourcePopoverAdapter.dependencyCacheTitle)
        submenu.autoenablesItems = false
        for choice in content.dependencyCacheChoices {
            let choiceItem = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
            choiceItem.state = choice.isCurrent ? .on : .off
            addChoice(choiceItem, standingFor: .dependencyCacheChoice(choice.dependencyCache))
            submenu.addItem(choiceItem)
        }
        submenu.addItem(.separator())
        let manageItem = NSMenuItem(title: RuntimeSourcePopoverAdapter.manageDependencyCachesTitle, action: nil, keyEquivalent: "")
        addChoice(manageItem, standingFor: .manageDependencyCaches)
        submenu.addItem(manageItem)
        let item = NSMenuItem(title: RuntimeSourcePopoverAdapter.dependencyCacheTitle, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func addChoice(_ item: NSMenuItem, standingFor row: Row) {
        item.target = self
        item.action = #selector(itemChosen(_:))
        rowsByItem[ObjectIdentifier(item)] = row
    }

    @objc private func itemChosen(_ sender: NSMenuItem) {
        guard let row = row(for: sender) else { return }
        switch row {
        case .source(let engineIdentifier):
            // The pop-up keeps showing the source chosen until the window's source follows.
            sourceSelectedRelay.accept(engineIdentifier)
        case .openFile:
            popUpButton.select(currentSourceItem)
            openFileRequestedRelay.accept(())
        case .dependencyCacheChoice(let dependencyCache):
            popUpButton.select(currentSourceItem)
            dependencyCacheSelectedRelay.accept(dependencyCache)
        case .manageDependencyCaches:
            popUpButton.select(currentSourceItem)
            dependencyCacheSettingsRequestedRelay.accept(())
        }
    }
}

#endif
