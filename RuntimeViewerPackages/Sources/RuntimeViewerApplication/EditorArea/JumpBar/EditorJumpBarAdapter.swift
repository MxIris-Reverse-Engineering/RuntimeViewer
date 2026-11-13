#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Puts an editor pane's jump bar on AppKitPlus's `NSPopUpPathControl` (proposal
/// `editor-jump-bar`), kept out of the view controller so it can be tested.
///
/// The control shows the path to an item of the document's `EditorJumpBarItemStore`; the adapter
/// shows the pane's location by selecting the item at its end. What the pane shows is the tab's to
/// decide: a choice made in a menu reaches `choiceSelected`, and the path changes only when the
/// pane's location does. The control selects the chosen item itself before it tells its delegate,
/// so `popUpPathControl(_:didSelect:)` puts the location's item straight back
/// (`RuntimeViewerUsingAppKit/AGENTS.md`, *Filter fields, filter bars and pop-up paths*).
///
/// Only images and objects are chosen. The engine and the folders lead to them: their rows open
/// submenus, and choosing one selects nothing, so the menu stays until an image or an object is
/// chosen. An image is a document root — its row has no submenu, and with no object chosen the path
/// ends in "No Selection", whose menu lists the image's objects once they are read. An object's
/// nested types are listed inline under it, indented, as Xcode lists a file's symbols.
@MainActor
public final class EditorJumpBarAdapter: NSObject {
    private let pathControl: NSPopUpPathControl

    private let itemStore: EditorJumpBarItemStore

    private var displayedLocation: EditorJumpBarLocation = .nothing

    private let choiceSelectedRelay = PublishRelay<EditorJumpBarChoice>()

    private let disposeBag = DisposeBag()

    /// The images and objects chosen in the jump bar's menus, with where the modifier keys held
    /// while choosing say to show them.
    public var choiceSelected: Signal<EditorJumpBarChoice> {
        choiceSelectedRelay.asSignal()
    }

    /// Whether the pane has the focus. An unfocused pane's path is drawn in the secondary label
    /// colour, as Xcode 27.2 draws it (`/Volumes/RE/Xcode/27.2-27B52/README.md`, "Editor jump
    /// bar"); the control asks for the colours as it rebuilds the path, so a change rebuilds it.
    public var isPaneFocused = true {
        didSet {
            guard isPaneFocused != oldValue else { return }
            pathControl.invalidateContent()
        }
    }

    public init(pathControl: NSPopUpPathControl, itemStore: EditorJumpBarItemStore) {
        self.pathControl = pathControl
        self.itemStore = itemStore
        super.init()
        pathControl.delegate = self
        applyTree()

        itemStore.treeRebuilt
            .emitOnNext { [weak self] in
                guard let self else { return }
                applyTree()
            }
            .disposed(by: disposeBag)

        itemStore.itemsMoved
            .emitOnNext {
                pathControl.invalidateContent()
            }
            .disposed(by: disposeBag)
    }

    /// Shows the path to `location`.
    public func show(_ location: EditorJumpBarLocation) {
        displayedLocation = location
        pathControl.selectedItem = itemStore.item(for: location)
    }

    /// The tree was made again: the root and the location's item are new objects.
    private func applyTree() {
        pathControl.rootItems = itemStore.rootItems
        pathControl.selectedItem = itemStore.item(for: displayedLocation)
    }
}

// MARK: - NSPopUpPathControlDelegate

extension EditorJumpBarAdapter: NSPopUpPathControlDelegate {
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, didSelect item: any NSPopUpPathItem) {
        pathControl.selectedItem = itemStore.item(for: displayedLocation)
        guard let target = (item as? EditorJumpBarItem)?.choiceTarget else { return }
        // A process without an application object — a test — has no event to read.
        let modifierFlags = NSApp?.currentEvent?.modifierFlags ?? []
        choiceSelectedRelay.accept(EditorJumpBarChoice(target: target, destination: SelectionRoute.Destination(listClickModifierFlags: modifierFlags)))
    }

    /// Images and objects are chosen; the engine and the folders only lead to them.
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, shouldEnableSelectionOf item: any NSPopUpPathItem) -> Bool {
        (item as? EditorJumpBarItem)?.choiceTarget != nil
    }

    /// An object's nested types are listed inline, indented under it; everything else opens a
    /// submenu of its children.
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, shouldSeparateDisplayOfChildItemsFor item: any NSPopUpPathItem) -> Bool {
        guard let item = item as? EditorJumpBarItem, case .object = item.content else { return true }
        return false
    }

    /// The secondary label colour in a pane without the focus; the control's own colours otherwise,
    /// which already follow the window.
    public func popUpPathControl(_ pathControl: NSPopUpPathControl, titleColorFor componentCell: NSPopUpPathComponentCell, at index: Int) -> NSColor? {
        isPaneFocused ? nil : .secondaryLabelColor
    }
}

#endif
