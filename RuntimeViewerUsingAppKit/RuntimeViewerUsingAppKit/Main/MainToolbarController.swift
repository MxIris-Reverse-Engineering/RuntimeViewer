import AppKit
import RxAppKit
import RuntimeViewerUI

final class MainToolbarController: NSObject, NSToolbarDelegate {
    protocol Delegate: AnyObject {}

    class IconButtonToolbarItem: NSToolbarItem {
        let button = ToolbarButton()

        convenience init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbols.SystemSymbolName) {
            self.init(itemIdentifier: itemIdentifier, icon: icon as SFSymbols.SymbolName)
        }

        convenience init(itemIdentifier: NSToolbarItem.Identifier, icon: RuntimeViewerSymbols) {
            self.init(itemIdentifier: itemIdentifier, icon: icon as SFSymbols.SymbolName)
        }

        init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbols.SymbolName) {
            super.init(itemIdentifier: itemIdentifier)
            view = button
            button.title = ""
            button.image = SFSymbols(name: icon).nsImage
        }
    }

    class SwitchSourceToolbarItem: NSToolbarItem {
        let popUpButton = NSPopUpButton()

        init() {
            super.init(itemIdentifier: .Main.switchSource)
            view = popUpButton
            popUpButton.controlSize = .large
            popUpButton.bezelStyle = .toolbar
        }
    }

    let toolbar: NSToolbar

    unowned let delegate: Delegate

    let sidebarBackItem = IconButtonToolbarItem(itemIdentifier: .Main.sidebarBack, icon: .chevronBackward).then {
        $0.label = "Back"
    }

    let contentBackItem = IconButtonToolbarItem(itemIdentifier: .Main.contentBack, icon: .chevronBackward).then {
        $0.isNavigational = true
        $0.label = "Back"
    }

    let attachItem = IconButtonToolbarItem(itemIdentifier: .Main.attach, icon: .inject).then {
        $0.label = "Attach Process"
    }

    let saveItem = IconButtonToolbarItem(itemIdentifier: .Main.save, icon: .squareAndArrowDown).then {
        $0.label = "Save"
    }

    let switchSourceItem = SwitchSourceToolbarItem().then {
        $0.label = "Runtime Source"
    }

    let generationOptionsItem = IconButtonToolbarItem(itemIdentifier: .Main.generationOptions, icon: .ellipsisCurlybraces).then {
        $0.label = "Generation Options"
    }

    let sharingServicePickerItem = NSSharingServicePickerToolbarItem(itemIdentifier: .Main.share)

    let fontSizeSmallerItem = IconButtonToolbarItem(itemIdentifier: .Main.fontSizeSmaller, icon: .textformatSizeSmaller).then {
        $0.label = "Font Size Smaller"
    }

    let fontSizeLargerItem = IconButtonToolbarItem(itemIdentifier: .Main.fontSizeLarger, icon: .textformatSizeLarger).then {
        $0.label = "Font Size Larger"
    }

    let loadFrameworksItem = IconButtonToolbarItem(itemIdentifier: .Main.loadFrameworks, icon: .latch2Case).then {
        $0.label = "Load Frameworks"
    }

    let installHelperItem = IconButtonToolbarItem(itemIdentifier: .Main.installHelper, icon: .wrenchAndScrewdriver).then {
        $0.label = "Install Helper"
    }

    init(delegate: Delegate) {
        self.delegate = delegate
        self.toolbar = NSToolbar()
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
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
            .inspectorTrackingSeparator,
            .flexibleSpace,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .Main.sidebarBack,
            .flexibleSpace,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .inspectorTrackingSeparator,
            .toggleInspector,
            .Main.share,
            .Main.save,
            .Main.switchSource,
            .Main.generationOptions,
            .Main.fontSizeSmaller,
            .Main.fontSizeLarger,
            .Main.loadFrameworks,
            .Main.installHelper,
            .Main.attach,
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .Main.sidebarBack:
            return sidebarBackItem
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
        case .Main.attach:
            return attachItem
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

extension NSToolbarItem.Identifier {
    enum Main {
        static let sidebarBack: NSToolbarItem.Identifier = "sidebarBack"
        static let contentBack: NSToolbarItem.Identifier = "contentBack"
        static let share: NSToolbarItem.Identifier = "share"
        static let save: NSToolbarItem.Identifier = "save"
        static let switchSource: NSToolbarItem.Identifier = "switchSource"
        static let generationOptions: NSToolbarItem.Identifier = "generationOptions"
        static let fontSizeSmaller: NSToolbarItem.Identifier = "fontSizeSmaller"
        static let fontSizeLarger: NSToolbarItem.Identifier = "fontSizeLarger"
        static let loadFrameworks: NSToolbarItem.Identifier = "loadFrameworks"
        static let installHelper: NSToolbarItem.Identifier = "installHelper"
        static let helperStatus: NSToolbarItem.Identifier = "helperStatus"
        static let attach: NSToolbarItem.Identifier = "attach"
    }
}
