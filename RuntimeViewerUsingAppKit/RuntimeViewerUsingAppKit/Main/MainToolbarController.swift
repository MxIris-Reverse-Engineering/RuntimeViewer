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
            inspectorButton.action = #selector(MainSplitViewController._toggleInspector(_:))
        }
    }

    class SaveToolbarItem: NSToolbarItem {
        let saveButton = ToolbarButton()

        init() {
            super.init(itemIdentifier: .Main.save)
            view = saveButton
            saveButton.title = ""
            saveButton.image = SFSymbol(systemName: .squareAndArrowDown).nsImage
        }
    }

    let toolbar: NSToolbar

    unowned let delegate: Delegate

    let backItem = BackToolbarItem()

    let inspectorItem = InspectorToolbarItem()

    let saveItem = SaveToolbarItem()

    lazy var inspectorTrackingSeparatorItem = NSTrackingSeparatorToolbarItem(identifier: .Main.inspectorTrackingSeparator, splitView: delegate.splitView, dividerIndex: 1)

    let sharingServicePickerItem = NSSharingServicePickerToolbarItem(itemIdentifier: .Main.share)

    init(delegate: Delegate) {
        self.delegate = delegate
        self.toolbar = NSToolbar()
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .Main.back, .flexibleSpace, .sidebarTrackingSeparator, .Main.save, .Main.share, .Main.inspectorTrackingSeparator, .flexibleSpace, .Main.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.Main.back, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .Main.inspectorTrackingSeparator, .Main.inspector, .Main.share, .Main.save]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .Main.back:
            return backItem
        case .Main.inspector:
            return inspectorItem
        case .Main.inspectorTrackingSeparator:
            return inspectorTrackingSeparatorItem
        case .Main.share:
            return sharingServicePickerItem
        case .Main.save:
            return saveItem
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
