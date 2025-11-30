import AppKit
import SFSymbols
import UIFoundationToolbox

final class ItemPopUpButton<Item: CaseIterable & CustomStringConvertible & RawRepresentable>: NSPopUpButton where Item.RawValue == Int {
    var onItem: Item? {
        didSet {
            guard let onItem else { return }
            item(withTitle: onItem.description)?.do {
                $0.state = .on
            }
        }
    }
    
    var icon: NSImage?
    
    var stateChanged: ((Item?) -> Void)?

    func setup() {
        pullsDown = true
        preferredEdge = .minY
        isBordered = false
        popUpButtonCell?.arrowPosition = .noArrow
        addItem(withTitle: "")
        item(at: 0)?.do {
            $0.image = icon
        }

        for item in Item.allCases {
            addItem(withTitle: item.description)
        }

        box.action { [weak self] button in
            guard let self else { return }
            button.itemArray.filter { $0 !== button.selectedItem }.forEach { $0.state = .off }
            button.selectedItem?.state = button.selectedItem?.state == .on ? .off : .on
            if button.selectedItem?.state == .on {
                stateChanged?(Item(rawValue: button.indexOfSelectedItem - 1))
            } else {
                stateChanged?(nil)
            }
        }
    }
}
