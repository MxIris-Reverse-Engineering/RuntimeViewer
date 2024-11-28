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
        static let sidebarBack: NSToolbarItem.Identifier = "sidebarBack"
        static let contentBack: NSToolbarItem.Identifier = "contentBack"
        static let share: NSToolbarItem.Identifier = "share"
        static let save: NSToolbarItem.Identifier = "save"
        static let inspector: NSToolbarItem.Identifier = "inspector"
        static let switchSource: NSToolbarItem.Identifier = "switchSource"
        static let inspectorTrackingSeparator: NSToolbarItem.Identifier = "inspectorTrackingSeparator"
        static let generationOptions: NSToolbarItem.Identifier = "generationOptions"
        static let fontSizeSmaller: NSToolbarItem.Identifier = "fontSizeSmaller"
        static let fontSizeLarger: NSToolbarItem.Identifier = "fontSizeLarger"
        static let loadFrameworks: NSToolbarItem.Identifier = "loadFrameworks"
        static let installHelper: NSToolbarItem.Identifier = "installHelper"
        static let attach: NSToolbarItem.Identifier = "attach"
    }
}

class MainToolbarController: NSObject, NSToolbarDelegate {
    protocol Delegate: AnyObject {
        var splitView: NSSplitView { get }
    }

    class IconButtonToolbarItem: NSToolbarItem {
        let button = ToolbarButton()

        convenience init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbol.SystemSymbolName) {
            self.init(itemIdentifier: itemIdentifier, icon: icon as SFSymbol.SymbolName)
        }
        
        convenience init(itemIdentifier: NSToolbarItem.Identifier, icon: RuntimeViewerSymbols) {
            self.init(itemIdentifier: itemIdentifier, icon: icon as SFSymbol.SymbolName)
        }
        
        init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbol.SymbolName) {
            super.init(itemIdentifier: itemIdentifier)
            view = button
            button.title = ""
            button.image = SFSymbol(name: icon).nsImage
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

    class SwitchSourceToolbarItem: NSToolbarItem {
        let segmentedControl = NSSegmentedControl(labels: ["Native", "Mac Catalyst"], trackingMode: .selectOne, target: nil, action: nil)
        init() {
            super.init(itemIdentifier: .Main.switchSource)
            view = segmentedControl
            segmentedControl.selectedSegment = 0
            segmentedControl.segmentDistribution = .fillEqually
        }
    }

    let toolbar: NSToolbar

    unowned let delegate: Delegate

    let sidebarBackItem = IconButtonToolbarItem(itemIdentifier: .Main.sidebarBack, icon: .chevronBackward)

    let contentBackItem = IconButtonToolbarItem(itemIdentifier: .Main.contentBack, icon: .chevronBackward).then {
        $0.isNavigational = true
    }

    let attachItem = IconButtonToolbarItem(itemIdentifier: .Main.attach, icon: .inject)
    
    let inspectorItem = InspectorToolbarItem()

    let saveItem = IconButtonToolbarItem(itemIdentifier: .Main.save, icon: .squareAndArrowDown)

    let switchSourceItem = SwitchSourceToolbarItem()

    let generationOptionsItem = IconButtonToolbarItem(itemIdentifier: .Main.generationOptions, icon: .ellipsisCurlybraces)

    lazy var inspectorTrackingSeparatorItem = NSTrackingSeparatorToolbarItem(identifier: .Main.inspectorTrackingSeparator, splitView: delegate.splitView, dividerIndex: 1)

    let sharingServicePickerItem = NSSharingServicePickerToolbarItem(itemIdentifier: .Main.share)

    let fontSizeSmallerItem = IconButtonToolbarItem(itemIdentifier: .Main.fontSizeSmaller, icon: .textformatSizeSmaller)

    let fontSizeLargerItem = IconButtonToolbarItem(itemIdentifier: .Main.fontSizeLarger, icon: .textformatSizeLarger)

    let loadFrameworksItem = IconButtonToolbarItem(itemIdentifier: .Main.loadFrameworks, icon: .latch2Case)
    
    let installHelperItem =  IconButtonToolbarItem(itemIdentifier: .Main.installHelper, icon: .wrenchAndScrewdriver)
    
    init(delegate: Delegate) {
        self.delegate = delegate
        self.toolbar = NSToolbar()
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .Main.sidebarBack,
            .flexibleSpace,
            .sidebarTrackingSeparator,
            .Main.contentBack,
            .Main.switchSource,
            .Main.attach,
            .Main.installHelper,
            .Main.loadFrameworks,
            .Main.fontSizeSmaller,
            .Main.fontSizeLarger,
            .Main.generationOptions,
            .Main.save,
            .Main.share,
            .Main.inspectorTrackingSeparator,
            .flexibleSpace,
            .Main.inspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .Main.sidebarBack,
            .flexibleSpace,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .Main.inspectorTrackingSeparator,
            .Main.inspector,
            .Main.share,
            .Main.save,
            .Main.switchSource,
            .Main.generationOptions,
            .Main.fontSizeSmaller,
            .Main.fontSizeLarger,
            .Main.loadFrameworks,
            .Main.installHelper,
            .Main.attach
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .Main.sidebarBack:
            return sidebarBackItem
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
        case .Main.contentBack:
            return contentBackItem
        case .Main.fontSizeSmaller:
            return fontSizeSmallerItem
        case .Main.fontSizeLarger:
            return fontSizeLargerItem
        case .Main.loadFrameworks:
            return loadFrameworksItem
        case .Main.installHelper:
            return installHelperItem
        default:
            return nil
        }
    }
}

extension NSToolbarItem.Identifier: @retroactive ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}
