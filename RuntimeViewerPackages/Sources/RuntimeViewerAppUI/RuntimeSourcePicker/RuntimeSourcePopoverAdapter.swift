#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerAppCore
import AppKitPlus
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

/// Opens the runtime source picker's popover — Xcode's scheme popover, on AppKitPlus's
/// `NSNavigationPopoverController` — and reports what the user chose in it. Kept out of the window
/// controller so that it can be tested.
///
/// The rows come from `content`, which the window's view model works out: one header per host with
/// its sources under it, the source the window is on checked, and while that source's engine is gone,
/// a dimmed row for it on top. Below the list, as the popover's footer, sit Open File… and — while the
/// window is on an offline file that can be paired with a dependency cache — Dependency Cache, which
/// pushes a level listing the caches, the one in use checked, with Manage in Settings… below them.
///
/// What it copies from Xcode 27.2's scheme picker (`/Volumes/RE/Xcode/27.2-27B52/README.md`, "The
/// scheme picker's popover", and "Scheme picker in the middle of the toolbar" §5): the popover opens
/// below the picker without animation, anchored to the picker's component at the component's whole
/// width; its filter field shows the filter icon and the placeholder Filter; it grows and shrinks with
/// its content and keeps its top edge; its rows are `RuntimeSourcePopoverCellView`s; and its content
/// is as wide as the widest title plus 36, up to 366. Where it departs:
///
/// - It filters by a case-insensitive run of characters, not by Xcode's fuzzy match, and never by the
///   user's language: Turkish pairs I with ı, so `uiview` would miss `UIView`. Matched characters are
///   bold, as in Xcode.
/// - The footer hides while filtering: AppKitPlus's `filteredItems` carries no footer.
/// - It pushes the cache level with push navigation, which Xcode's single-level scheme list does not
///   need.
///
/// A choice is reported once the popover has closed, as Xcode applies a scheme on close.
@MainActor
public final class RuntimeSourcePopoverAdapter: NSObject {
    /// The widest a level's content gets before the popover's padding — Xcode's cap in
    /// `calculateDesiredPopoverWidth(visibleItems:popoverController:)`.
    static let maximumContentWidth: CGFloat = 366

    /// What a row with a checkmark and an icon adds to its title's width.
    static let checkedRowExtraWidth: CGFloat = 36

    static let openFileTitle = "Open File…"

    static let dependencyCacheTitle = "Dependency Cache"

    static let manageDependencyCachesTitle = "Manage in Settings…"

    /// Measures titles as Xcode's scheme picker does, with a label in the 13-point system font.
    private static let sizingLabel = NSTextField(labelWithString: "").then {
        $0.font = .systemFont(ofSize: NSFont.systemFontSize)
    }

    /// What one of the popover's items stands for.
    enum Row: Equatable {
        case source(engineIdentifier: String)
        case openFile
        case dependencyCache
        case dependencyCacheChoice(RuntimeOfflineFile.DependencyCache?)
        case manageDependencyCaches
    }

    /// Rows under a header, or rows without one.
    struct ItemGroup {
        var header: NSNavigationPopoverItem?
        var rows: [NSNavigationPopoverItem]

        var items: [NSNavigationPopoverItem] {
            (header.map { [$0] } ?? []) + rows
        }
    }

    /// What the popover lists the next time it opens.
    public var content: RuntimeSourcePickerContent = .empty

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

    /// The popover on screen, or the last one shown.
    private(set) var popoverController: NSNavigationPopoverController?

    private weak var presentingPicker: RuntimeSourcePicker?

    /// What each item of the current popover stands for.
    private var rowsByItem: [ObjectIdentifier: Row] = [:]

    /// The rows that draw as `RuntimeSourcePopoverCellView`s, made once per popover.
    private var cellViewsByItem: [ObjectIdentifier: RuntimeSourcePopoverCellView] = [:]

    /// The first level, as filtering rebuilds it.
    private(set) var sourceGroups: [ItemGroup] = []

    /// The cache level, once pushed.
    private(set) var dependencyCacheGroups: [ItemGroup] = []

    /// When the last popover closed, by the event that closed it: a press on the picker that closes
    /// its popover does not open it again.
    private var lastCloseEventTimestamp: TimeInterval?

    public override init() {
        super.init()
    }

    /// Opens the popover below `picker`, or closes it when it is already open — a second press on a
    /// pop-up closes it.
    public func showPopover(from picker: RuntimeSourcePicker) {
        if let popoverController, popoverController.isShown {
            popoverController.closePopover()
            return
        }
        if let currentEvent = NSApp?.currentEvent, currentEvent.timestamp == lastCloseEventTimestamp {
            return
        }
        let controller = makePopoverController()
        presentingPicker = picker
        picker.isShowingPopover = true
        // Xcode anchors to the component at its natural width, which a narrowed picker may not show.
        let anchorRect = NSRect(x: 0, y: 0, width: picker.componentWidth, height: picker.bounds.height)
        controller.show(relativeTo: anchorRect, of: picker, preferredEdge: .maxY, animated: false)
    }

    /// Closes the popover, if it is open.
    public func closePopover() {
        popoverController?.closePopover()
    }

    /// A controller listing `content`, set up as `DVTPathCell.handleNavigationPopoverDisplay` sets
    /// up Xcode's.
    func makePopoverController() -> NSNavigationPopoverController {
        rowsByItem = [:]
        cellViewsByItem = [:]
        dependencyCacheGroups = []
        sourceGroups = makeSourceGroups()
        let controller = NSNavigationPopoverController(
            items: sourceGroups.flatMap(\.items),
            footerItems: makeFooterItems(),
            title: nil
        )
        controller.delegate = self
        controller.hierarchyStyle = .pushNavigation
        controller.usesFilterIcon = true
        controller.resizingBehavior = [.grows, .shrinks, .keepsTopStable, .preservesWidthWhenChangingItemGroup]
        popoverController = controller
        return controller
    }

    /// What `item` stands for, in the current popover.
    func row(for item: NSNavigationPopoverItem) -> Row? {
        rowsByItem[ObjectIdentifier(item)]
    }

    /// The view `item`'s row shows, when it is a checked kind of row.
    func cellView(for item: NSNavigationPopoverItem) -> RuntimeSourcePopoverCellView? {
        cellViewsByItem[ObjectIdentifier(item)]
    }

    // MARK: - Items

    private func makeSourceGroups() -> [ItemGroup] {
        var groups: [ItemGroup] = []
        if let disconnectedSource = content.disconnectedSource {
            groups.append(ItemGroup(header: nil, rows: [makeSourceItem(disconnectedSource)]))
        }
        for section in content.sections where !section.sources.isEmpty {
            groups.append(ItemGroup(
                header: NSNavigationPopoverItem.headerItem(withTitle: section.title),
                rows: section.sources.map(makeSourceItem)
            ))
        }
        return groups
    }

    private func makeSourceItem(_ source: RuntimeSourcePickerContent.Source) -> NSNavigationPopoverItem {
        makeCheckedItem(
            title: source.title,
            image: source.image,
            isChecked: source.isCurrent,
            isEnabled: source.isEnabled,
            row: .source(engineIdentifier: source.engineIdentifier)
        )
    }

    private func makeCheckedItem(title: String, image: NSImage?, isChecked: Bool, isEnabled: Bool, row: Row) -> NSNavigationPopoverItem {
        let item = NSNavigationPopoverItem(title: title)
        item.isEnabled = isEnabled
        let cellView = RuntimeSourcePopoverCellView()
        cellView.title = title
        cellView.icon = image
        cellView.isChecked = isChecked
        cellView.isEnabled = isEnabled
        rowsByItem[ObjectIdentifier(item)] = row
        cellViewsByItem[ObjectIdentifier(item)] = cellView
        return item
    }

    private func makeFooterItems() -> [NSNavigationPopoverItem] {
        var items = [makeCommandItem(title: Self.openFileTitle, row: .openFile)]
        if !content.dependencyCacheChoices.isEmpty {
            let dependencyCacheItem = makeCommandItem(title: Self.dependencyCacheTitle, row: .dependencyCache)
            dependencyCacheItem.style = .group
            items.append(dependencyCacheItem)
        }
        return items
    }

    private func makeCommandItem(title: String, row: Row) -> NSNavigationPopoverItem {
        let item = NSNavigationPopoverItem(title: title)
        rowsByItem[ObjectIdentifier(item)] = row
        return item
    }

    private func makeDependencyCacheGroups() -> [ItemGroup] {
        let rows = content.dependencyCacheChoices.map { choice in
            makeCheckedItem(
                title: choice.title,
                image: nil,
                isChecked: choice.isCurrent,
                isEnabled: true,
                row: .dependencyCacheChoice(choice.dependencyCache)
            )
        }
        return [ItemGroup(header: nil, rows: rows)]
    }

    // MARK: - Filtering

    /// Where `filterString` occurs in `title`, ignoring case but not following the user's language.
    nonisolated static func matchedRange(of filterString: String, in title: String) -> NSRange? {
        let range = (title as NSString).range(of: filterString, options: [.caseInsensitive])
        return range.location == NSNotFound ? nil : range
    }

    /// The rows of `groups` whose title holds `filterString`, each under its header, the headers of
    /// groups with no such row left out; the matches go to the rows' cells.
    func filteredItems(in groups: [ItemGroup], matching filterString: String) -> [NSNavigationPopoverItem] {
        var items: [NSNavigationPopoverItem] = []
        for group in groups {
            let matchedRows = group.rows.filter { row in
                let range = Self.matchedRange(of: filterString, in: row.title)
                cellView(for: row)?.filterMatchRanges = range.map { [$0] } ?? []
                return range != nil
            }
            guard !matchedRows.isEmpty else { continue }
            if let header = group.header {
                items.append(header)
            }
            items += matchedRows
        }
        return items
    }

    /// Whether `controller` shows the cache level now. A pop through the back button tells no one,
    /// so the level is read off the items on show.
    private func showsDependencyCacheLevel(_ controller: NSNavigationPopoverController) -> Bool {
        let cacheItems = Set(dependencyCacheGroups.flatMap(\.items).map(ObjectIdentifier.init))
        return controller.items.contains { cacheItems.contains(ObjectIdentifier($0)) }
    }

    // MARK: - Width

    /// The widest title among `items`, plus 36 for a row with a checkmark and an icon, up to 366.
    func contentWidth(for items: [NSNavigationPopoverItem]) -> CGFloat {
        var width: CGFloat = 0
        for item in items where item.style != .separator {
            Self.sizingLabel.stringValue = item.title
            let titleWidth = Self.sizingLabel.fittingSize.width
            width = max(width, cellView(for: item) == nil ? titleWidth : titleWidth + Self.checkedRowExtraWidth)
        }
        return min(width, Self.maximumContentWidth)
    }
}

// MARK: - NSNavigationPopoverControllerDelegate

extension RuntimeSourcePopoverAdapter: NSNavigationPopoverControllerDelegate {
    public func navigationPopoverController(_ controller: NSNavigationPopoverController, didSelect item: NSNavigationPopoverItem) -> Bool {
        guard row(for: item) == .dependencyCache else { return true }
        dependencyCacheGroups = makeDependencyCacheGroups()
        controller.pushItems(
            dependencyCacheGroups.flatMap(\.items),
            footerItems: [makeCommandItem(title: Self.manageDependencyCachesTitle, row: .manageDependencyCaches)],
            title: nil,
            animated: true
        )
        return false
    }

    public func navigationPopoverController(_ controller: NSNavigationPopoverController, didCloseWithSelectedItem item: NSNavigationPopoverItem?) {
        guard controller === popoverController else { return }
        presentingPicker?.isShowingPopover = false
        presentingPicker = nil
        lastCloseEventTimestamp = NSApp?.currentEvent?.timestamp
        guard let item, let row = row(for: item) else { return }
        switch row {
        case .source(let engineIdentifier):
            sourceSelectedRelay.accept(engineIdentifier)
        case .openFile:
            openFileRequestedRelay.accept(())
        case .dependencyCacheChoice(let dependencyCache):
            dependencyCacheSelectedRelay.accept(dependencyCache)
        case .manageDependencyCaches:
            dependencyCacheSettingsRequestedRelay.accept(())
        case .dependencyCache:
            break
        }
    }

    public func navigationPopoverController(_ controller: NSNavigationPopoverController, viewFor item: NSNavigationPopoverItem) -> NSView? {
        cellView(for: item)
    }

    public func navigationPopoverController(_ controller: NSNavigationPopoverController, widthFor items: [NSNavigationPopoverItem]) -> CGFloat {
        contentWidth(for: items)
    }

    public func navigationPopoverController(_ controller: NSNavigationPopoverController, filterStringDidChange filterString: String) {
        let groups = showsDependencyCacheLevel(controller) ? dependencyCacheGroups : sourceGroups
        guard !filterString.isEmpty else {
            // The controller shows every row again by itself; only the bold goes.
            for row in groups.flatMap(\.rows) {
                cellView(for: row)?.filterMatchRanges = []
            }
            return
        }
        controller.filteredItems = filteredItems(in: groups, matching: filterString)
    }
}

#endif
