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
        static let switchSource: NSToolbarItem.Identifier = "switchSource"
        static let inspectorTrackingSeparator: NSToolbarItem.Identifier = "inspectorTrackingSeparator"
        static let generationOptions: NSToolbarItem.Identifier = "generationOptions"
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
    
    class SwitchSourceToolbarItem: NSToolbarItem {
        let segmentedControl = NSSegmentedControl(labels: ["Native", "Mac Catalyst"], trackingMode: .selectOne, target: nil, action: nil)
        init() {
            super.init(itemIdentifier: .Main.switchSource)
            view = segmentedControl
            segmentedControl.selectedSegment = 0
        }
    }

    class GenerationOptionsToolbarItem: NSToolbarItem {
        let button = ToolbarButton()
        
        init() {
            super.init(itemIdentifier: .Main.generationOptions)
            view = button
            button.title = ""
            button.image = SFSymbol(systemName: .ellipsisCurlybraces).nsImage
        }
    }
    
    let toolbar: NSToolbar

    unowned let delegate: Delegate

    let backItem = BackToolbarItem()

    let inspectorItem = InspectorToolbarItem()

    let saveItem = SaveToolbarItem()

    let switchSourceItem = SwitchSourceToolbarItem()
    
    let generationOptionsItem = GenerationOptionsToolbarItem()
    
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
        [.toggleSidebar, .Main.back, .flexibleSpace, .sidebarTrackingSeparator, .Main.switchSource, .Main.generationOptions, .Main.save, .Main.share, .Main.inspectorTrackingSeparator, .flexibleSpace, .Main.inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.Main.back, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .Main.inspectorTrackingSeparator, .Main.inspector, .Main.share, .Main.save, .Main.switchSource, .Main.generationOptions]
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
        case .Main.switchSource:
            return switchSourceItem
        case .Main.generationOptions:
            return generationOptionsItem
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
