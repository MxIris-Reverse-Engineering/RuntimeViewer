import AppKit
import RxSwift
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerCommunication

extension RuntimeSource: @retroactive RxMenuItemRepresentable {}

extension RuntimeSource: MainMenuItemRepresentable {
    public var title: String { description }

    var icon: NSImage {
        switch self {
        case .local:
            return .symbol(systemName: .display)
        case .remote(_, let identifier, _):
            if identifier == .macCatalyst {
                return .symbol(systemName: .display)
            } else {
                return .symbol(name: RuntimeViewerSymbols.appFill)
            }
        case .bonjourClient:
            return .symbol(systemName: .bonjour)
        case .bonjourServer:
            return .symbol(systemName: .bonjour)
        }
    }
}

extension Reactive where Base: NSMenu {
    func selectedItemIndex() -> ControlEvent<Int> {
        let source = itemSelected(Any?.self).compactMap { [weak base] menuItem, _ -> Int? in
            guard let self = base else { return nil }
            return self.items.firstIndex(of: menuItem)
        }.share()
        return ControlEvent(events: source)
    }
}

protocol MainMenuItemRepresentable: RxMenuItemRepresentable {
    var icon: NSImage { get }
}

extension Reactive where Base: NSPopUpButton {
    func items<MenuItemRepresentable: MainMenuItemRepresentable>() -> Binder<[MenuItemRepresentable]> {
        Binder(base) { (target: NSPopUpButton, items: [MenuItemRepresentable]) in
            target.removeAllItems()
            items.forEach { item in
                target.addItem(withTitle: item.title)
                if let menuItem = target.item(withTitle: item.title) {
                    menuItem.image = item.icon
                }
            }
        }
    }
}
