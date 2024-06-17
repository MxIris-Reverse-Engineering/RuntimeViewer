//
//  MainToolbarController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import AppKit
import RuntimeViewerUI

extension NSToolbarItem.Identifier {
    enum Main {
        static let back: NSToolbarItem.Identifier = "back"
        static let share: NSToolbarItem.Identifier = "share"
        static let save: NSToolbarItem.Identifier = "save"
        static let sidebar: NSToolbarItem.Identifier = "sidebar"
        static let inspector: NSToolbarItem.Identifier = "inspector"
        static let inspectorTrackingSeparator: NSToolbarItem.Identifier = "inspectorTrackingSeparator"
    }
}

class MainToolbarController: NSObject, NSToolbarDelegate {
    protocol Delegate: AnyObject {
        var splitView: NSSplitView { get }
    }
    
    class BackToolbarItem: NSToolbarItem {
        let backButton = ToolbarButton()

        init() {
            super.init(itemIdentifier: .Main.back)
            view = backButton
            backButton.title = ""
            backButton.image = SFSymbol(systemName: .chevronBackward).nsImage
        }
    }
    
    class InspectorToolbarItem: NSToolbarItem {
        let inspectorButton = ToolbarButton()
        init() {
            super.init(itemIdentifier: .Main.inspector)
            view = inspectorButton
            inspectorButton.title = ""
            inspectorButton.image = SFSymbol(systemName: .sidebarRight).nsImage
        }
    }

//    class InspectorTrackingSeparatorToolbarItem: NSTrackingSeparatorToolbarItem {
//        init() {
//            super.init(itemIdentifier: .Main.inspectorTrackingSeparator)
//        }
//    }
    
    let toolbar: NSToolbar
    
    unowned let delegate: Delegate
    
    let backItem = BackToolbarItem()

    let inspectorItem = InspectorToolbarItem()
    
    lazy var inspectorTrackingSeparatorItem: NSTrackingSeparatorToolbarItem = .init(identifier: .Main.inspectorTrackingSeparator, splitView: delegate.splitView, dividerIndex: 1)
    
    init(delegate: Delegate) {
        self.delegate = delegate
        self.toolbar = NSToolbar()
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.Main.back, .toggleSidebar, .sidebarTrackingSeparator, .Main.inspectorTrackingSeparator, .Main.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.Main.back, .toggleSidebar, .sidebarTrackingSeparator, .Main.inspectorTrackingSeparator, .Main.inspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .Main.back:
            return backItem
        case .Main.inspector:
            return inspectorItem
        case .Main.inspectorTrackingSeparator:
            return inspectorTrackingSeparatorItem
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
