//
//  MainToolbarController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import AppKit
import RuntimeViewerUI

extension NSToolbarItem.Identifier {
    static let back: Self = "back"
    static let share: Self = "share"
    static let save: Self = "save"
}

class MainToolbarController: NSObject, NSToolbarDelegate {
    class BackToolbarItem: NSToolbarItem {
        let backButton = ToolbarButton()

        init() {
            super.init(itemIdentifier: .back)
            view = backButton
            backButton.title = ""
            backButton.image = SFSymbol(systemName: .chevronBackward).nsImage
        }
    }
    

    let toolbar: NSToolbar

    let backItem = BackToolbarItem()

    override init() {
        self.toolbar = NSToolbar()
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.back, .sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .back:
            return backItem
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}
