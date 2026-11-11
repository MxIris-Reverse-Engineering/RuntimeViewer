import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// One entry of a list's context menu, for `NSMenu.rx.items` / `itemSelected`.
///
/// Carries its own `action`, so the code that installs the menu runs whatever
/// entry was chosen without knowing who contributed it — a generic view
/// controller cannot host `@objc` menu actions, and a subclass appends entries
/// of its own to its superclass's.
struct ContextMenuItem: RxMenuItemRepresentable {
    let title: String
    var image: NSImage?
    let action: () -> Void

    init(title: String, image: NSImage? = nil, action: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.action = action
    }

    /// The entry for a command every list offers on a runtime object, titled as
    /// in every other menu (`RuntimeObjectAction+Menu`).
    init(_ action: RuntimeObjectAction, perform: @escaping () -> Void) {
        self.init(title: action.menuTitle, image: action.menuImage, action: perform)
    }
}

extension NSTableView {
    /// Gives the table — or outline — a context menu built for the clicked row
    /// each time it opens, and runs the entry chosen.
    ///
    /// A click below the rows, or on a row `items` has nothing for, opens
    /// nothing: AppKit does not pop up an empty menu.
    func installContextMenu(items: @escaping (_ clickedRow: Int) -> [ContextMenuItem]) -> Disposable {
        let contextMenu = NSMenu()
        menu = contextMenu
        let itemsSource = contextMenu.rx.needsUpdate
            .asObservable()
            .map { [weak self] _ -> [ContextMenuItem] in
                guard let self, clickedRow >= 0 else { return [] }
                return items(clickedRow)
            }
        let itemsBinding = contextMenu.rx.items(source: itemsSource)({ menuItem, entry in menuItem.image = entry.image })
        let selection = contextMenu.rx.itemSelected(ContextMenuItem.self)
            .map(\.item)
            .asSignal(onErrorSignalWith: .empty())
            .emitOnNext { $0.action() }
        return Disposables.create(itemsBinding, selection)
    }
}
