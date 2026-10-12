#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import RuntimeViewerArchitectures

/// Puts the Find page's mode path, `Find ▸ Text ▸ Containing`, on AppKitPlus's
/// `NSPopUpPathControl`, kept out of the view controller so it can be tested.
///
/// The control derives its path from a tree of items, while the view model sends a path of
/// components. The adapter builds the whole tree once, from `FindModePathComponent.path(for:)` —
/// the rule the view model's path comes from — and shows a path by selecting its last item. The
/// items stay the same objects for as long as the adapter lives: the control compares them by
/// pointer.
///
/// The path is the view model's to decide: a choice made in a menu reaches `choiceSelected`, and
/// the path changes only when the view model sends a new one. The control selects the chosen item
/// itself before it tells its delegate, so `popUpPathControl(_:didSelect:)` puts the view model's
/// path straight back; the path the control rebuilds right after never shows the chosen item on
/// its own, such as `Find ▸ Members` without its match style.
@MainActor
public final class FindModePathControlAdapter: NSObject {
    private let pathControl: NSPopUpPathControl

    /// `Find`, whose children are the modes, whose children are their match styles.
    let rootItem: Item

    private var displayedPath: [FindModePathComponent] = []

    private let choiceSelectedRelay = PublishRelay<FindModePathChoice>()

    /// The choices the user makes in the path's menus.
    public var choiceSelected: Signal<FindModePathChoice> {
        choiceSelectedRelay.asSignal()
    }

    public init(pathControl: NSPopUpPathControl) {
        self.pathControl = pathControl
        self.rootItem = Self.makeItemTree()
        super.init()
        // How Xcode's Find navigator sets up its mode path: every component is a choice of its
        // own, so the menus list one level and no row gets a submenu.
        pathControl.selectsComponentsOneAtATime = true
        pathControl.rootItems = [rootItem]
        pathControl.delegate = self
    }

    /// Shows `path`, as the view model sent it.
    public func show(_ path: [FindModePathComponent]) {
        displayedPath = path
        pathControl.selectedItem = item(at: path)
    }

    /// The item that ends `path`: `Find`, then the child showing each later component's choice.
    func item(at path: [FindModePathComponent]) -> Item? {
        guard !path.isEmpty else { return nil }
        var item = rootItem
        for component in path.dropFirst() {
            guard let child = item.children.first(where: { $0.choice == component.choice }) else { break }
            item = child
        }
        return item
    }

    /// The tree every path of the view model's walks down: each level's items are the choices the
    /// path's component at that level offers in its menu.
    private static func makeItemTree() -> Item {
        let defaultPath = FindModePathComponent.path(for: FindQuery())
        let rootItem = Item(title: defaultPath[0].title, choice: nil, groupIdentifier: nil)
        rootItem.children = makeItems(for: defaultPath[1].menuChoices, parentItem: rootItem)
        for modeItem in rootItem.children {
            guard case .mode(let mode)? = modeItem.choice else { continue }
            let modePath = FindModePathComponent.path(for: FindQuery(mode: mode))
            if modePath.count > 2 {
                modeItem.children = makeItems(for: modePath[2].menuChoices, parentItem: modeItem)
            }
        }
        return rootItem
    }

    /// One item per choice. A choice the view model sets apart starts a group of its own, which
    /// is where the control's menu puts a separator.
    private static func makeItems(for choices: [FindModePathChoice], parentItem: Item) -> [Item] {
        var groupIndex = 0
        return choices.map { choice in
            if choice.isPrecededBySeparator {
                groupIndex += 1
            }
            let item = Item(title: choice.title, choice: choice, groupIdentifier: groupIndex == 0 ? nil : String(groupIndex))
            item.parentItem = parentItem
            return item
        }
    }
}

// MARK: - Items

extension FindModePathControlAdapter {
    /// A component of the mode path, and a row of the menu that component opens.
    @MainActor
    final class Item: NSObject, NSPopUpPathItem {
        let pathComponentName: String

        /// What choosing the item asks for; `nil` for `Find`.
        let choice: FindModePathChoice?

        let groupIdentifier: String?

        weak var parentItem: (any NSPopUpPathItem)?

        var children: [Item] = []

        init(title: String, choice: FindModePathChoice?, groupIdentifier: String?) {
            self.pathComponentName = title
            self.choice = choice
            self.groupIdentifier = groupIdentifier
        }

        var childItems: [any NSPopUpPathItem]? {
            children
        }

        var isLeaf: Bool {
            children.isEmpty
        }
    }
}

// MARK: - NSPopUpPathControlDelegate

extension FindModePathControlAdapter: NSPopUpPathControlDelegate {
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, didSelect item: any NSPopUpPathItem) {
        pathControl.selectedItem = self.item(at: displayedPath)
        guard let choice = (item as? Item)?.choice else { return }
        choiceSelectedRelay.accept(choice)
    }

    /// `Find` is a title rather than a choice. Xcode's switches between Find and Replace; the
    /// navigator does not replace.
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, shouldPopUpMenuFor componentCell: NSPopUpPathComponentCell, item: (any NSPopUpPathItem)?) -> Bool {
        item !== rootItem
    }

    public func popUpPathControl(_ pathControl: NSPopUpPathControl, shouldEnableSelectionOf item: any NSPopUpPathItem) -> Bool {
        item !== rootItem
    }

    /// Xcode accents every choice other than the default one; see `FindModePathChoice.isAccented`.
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, titleColorFor componentCell: NSPopUpPathComponentCell, at index: Int) -> NSColor? {
        (componentCell.representedObject as? Item)?.choice?.isAccented == true ? .controlAccentColor : nil
    }
}

#endif
