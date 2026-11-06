import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerMCPBridge
import RuntimeViewerSettings

final class MainToolbarController: NSObject, NSToolbarDelegate {
    protocol Delegate: AnyObject {}

    final class NavigationToolbarItem: NSToolbarItem {
//        let previousItem = IconButtonToolbarItem(itemIdentifier: .Main.navigationPrevious, icon: .chevronBackward).then {
//            $0.label = "Previous"
//        }
//        
//        let nextItem = IconButtonToolbarItem(itemIdentifier: .Main.navigationNext, icon: .chevronForward).then {
//            $0.label = "Next"
//        }
        
        /// `setMenu(_:forSegment:)` raises `NSExceptionName.rangeException`
        /// on an out-of-range index, so the segment configuration below
        /// names its indexes instead of repeating bare literals.
        private static let backwardSegment: Int = 0
        private static let forwardSegment: Int = 1

        let segmentedControl = NSSegmentedControl()

        /// Long-press history menus. Alive for the item's lifetime and
        /// refilled in place by `NavigationHistoryMenuBuilder`;
        /// `attachHistoryMenus(hasBackwardItems:hasForwardItems:)` decides
        /// whether each one is actually reachable.
        let backwardHistoryMenu = NSMenu()

        let forwardHistoryMenu = NSMenu()
        
        init() {
            super.init(itemIdentifier: .Main.navigation)
            isNavigational = true
            view = segmentedControl
            segmentedControl.segmentCount = 2
            segmentedControl.segmentStyle = .automatic
            segmentedControl.trackingMode = .momentary
            segmentedControl.setImage(.symbol(systemName: .chevronBackward), forSegment: Self.backwardSegment)
            segmentedControl.setImage(.symbol(systemName: .chevronForward), forSegment: Self.forwardSegment)

            // A segment pops its menu on press-and-hold only while the
            // control ALSO has a non-nil `action`; with a menu but no
            // action AppKit pops the menu on a plain click and
            // single-step navigation is lost. `rx.selectedSegment`
            // installs its ActionProxy lazily on first subscription —
            // i.e. after this initializer returns — so a placeholder is
            // installed here to hold the invariant regardless of
            // subscription order. The proxy preserves this pair and
            // keeps forwarding to it.
            segmentedControl.target = self
            segmentedControl.action = #selector(navigationSegmentPressed)

            // The indicator arrow would make the segments read as pop-up
            // buttons; Safari-style back/forward shows no such chrome.
            segmentedControl.setShowsMenuIndicator(false, forSegment: Self.backwardSegment)
            segmentedControl.setShowsMenuIndicator(false, forSegment: Self.forwardSegment)
        }

        /// Attaches each history menu only when it has rows — a segment
        /// wired to an empty `NSMenu` still pops an empty box on a long
        /// press.
        func attachHistoryMenus(hasBackwardItems: Bool, hasForwardItems: Bool) {
            segmentedControl.setMenu(hasBackwardItems ? backwardHistoryMenu : nil, forSegment: Self.backwardSegment)
            segmentedControl.setMenu(hasForwardItems ? forwardHistoryMenu : nil, forSegment: Self.forwardSegment)
        }

        /// Placeholder keeping `action` non-nil — see `init`. Real click
        /// handling runs through `rx.selectedSegment` in
        /// `MainWindowController.setupBindings(for:)`.
        @objc private func navigationSegmentPressed() {}
    }
    
    class IconButtonToolbarItem: NSToolbarItem {
        let button = ToolbarButton()
        
        init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbols.SystemSymbolName) {
            super.init(itemIdentifier: itemIdentifier)
            commonInit(icon: icon)
        }

        init(itemIdentifier: NSToolbarItem.Identifier, icon: RuntimeViewerSymbols) {
            super.init(itemIdentifier: itemIdentifier)
            commonInit(icon: icon)
        }

        init(itemIdentifier: NSToolbarItem.Identifier, icon: SFSymbols.SymbolName) {
            super.init(itemIdentifier: itemIdentifier)
            commonInit(icon: icon)

        }
        
        private func commonInit(icon: SFSymbols.SymbolName) {
            view = button
            button.title = ""
            button.image = SFSymbols(name: icon).nsImage
        }
    }

    class MCPStatusToolbarItem: IconButtonToolbarItem {
        init() {
            super.init(itemIdentifier: .Main.mcpStatus, icon: .serverRack)
        }
    }

    /// Xcode 27.2's Add Editor toolbar item (`IDEAddEditorToolbarViewController`): a button with no
    /// action of its own, only a menu — Tab, then Editor Pane On Right and Editor Pane Below — whose
    /// items go up the responder chain to the key window's `MainWindowController`, as the File menu's
    /// do. The menu shows no key equivalents, as Xcode's does not.
    final class AddEditorToolbarItem: NSMenuToolbarItem {
        init() {
            super.init(itemIdentifier: .Main.addEditor)
            label = "Add Editor"
            paletteLabel = "Add Editor"
            toolTip = "Add Editor Tabs or Editor Panes"
            showsIndicator = false
            image = NSImage(systemSymbolName: "inset.filled.righthalf.rectangle", accessibilityDescription: "Add Editor")
            menu = NSMenu {
                NSMenuItem("Tab", action: #selector(MainWindowController.newTab(_:)))
                    .image(NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil))
                NSMenuItem.separator()
                NSMenuItem("Editor Pane On Right", action: #selector(MainWindowController.newEditorPaneOnRight(_:)))
                    .image(NSImage(systemSymbolName: "inset.filled.righthalf.rectangle", accessibilityDescription: nil))
                NSMenuItem("Editor Pane Below", action: #selector(MainWindowController.newEditorPaneBelow(_:)))
                    .image(NSImage(systemSymbolName: "inset.filled.bottomhalf.rectangle", accessibilityDescription: nil))
            }
        }
    }

    /// The activity capsule in the middle of the toolbar in Xcode 26's style — its Activity View,
    /// which Xcode 27 replaced with the window title's progress ring. It holds the runtime source
    /// picker at its leading edge, where Xcode 26 holds its scheme picker.
    final class ActivityToolbarItem: NSToolbarItem {
        let activityView = ToolbarActivityView(showsSourcePicker: true)

        init() {
            super.init(itemIdentifier: .Main.activity)
            view = activityView
            label = "Activity"
            visibilityPriority = .high
        }
    }

    /// The capsule's share of the toolbar's width — Xcode's `IDEActivityViewProportionalWidthPercentage`
    /// of 40.
    static let activityCapsuleWidthRatio: CGFloat = 0.4

    /// No preference for the centered item's width, the value a toolbar starts with: the runtime source
    /// picker in the middle keeps its own width.
    static let noCenteredItemWidthRatio: CGFloat = -1

    /// The style the toolbar is in — the one the user's setting stands for on this system, never
    /// `automatic` — which `apply(activityStyle:)` changes.
    private(set) var activityStyle = Settings.ToolbarActivityStyle.automatic.resolved

    /// Whether the toolbar has asked for its items. Until it has, a change of style needs nothing
    /// but the next answer.
    private var hasProvidedItems = false

    /// The runtime source picker in the middle of the toolbar in Xcode 27's style, where Xcode 27 puts
    /// its scheme and run destination; Xcode 26's style shows the picker in the activity capsule
    /// instead. Xcode wraps the item in a one-item group, which changes nothing that shows.
    final class SwitchSourceToolbarItem: NSToolbarItem {
        let pickerView = RuntimeSourcePickerToolbarView()

        var picker: RuntimeSourcePicker {
            pickerView.picker
        }

        init() {
            super.init(itemIdentifier: .Main.switchSource)
            view = pickerView
            visibilityPriority = .high
        }
    }

    /// The runtime source in the classic toolbar, the one RuntimeViewer had before it followed Xcode: a
    /// pop-up button before the trailing buttons, whose menu `RuntimeSourceMenuAdapter` fills.
    final class SwitchSourcePopUpToolbarItem: NSToolbarItem {
        let popUpButton = NSPopUpButton()

        init() {
            super.init(itemIdentifier: .Main.switchSourcePopUp)
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

    let navigationItem = NavigationToolbarItem()

    /// The title in Xcode 26's style, where the capsule shows the activity.
    let titleItem = TitleToolbarItem(itemIdentifier: .Main.title)

    /// The title in Xcode 27's style, which shows the activity where Xcode 27 does: in place of its icon.
    let activityTitleItem = TitleToolbarItem(itemIdentifier: .Main.activityTitle, showsActivity: true)

    /// Both titles, for what each shows in either style.
    var titleItems: [TitleToolbarItem] {
        [titleItem, activityTitleItem]
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

    let switchSourcePopUpItem = SwitchSourcePopUpToolbarItem().then {
        $0.label = "Runtime Source"
    }

    let generationOptionsItem = IconButtonToolbarItem(itemIdentifier: .Main.generationOptions, icon: .ellipsisCurlybraces).then {
        $0.label = "Generation Options"
    }

    let sharingServicePickerItem = NSSharingServicePickerToolbarItem(itemIdentifier: .Main.share)

    let loadFrameworksItem = IconButtonToolbarItem(itemIdentifier: .Main.loadFrameworks, icon: .latch2Case).then {
        $0.label = "Load Frameworks"
    }

    let installHelperItem = IconButtonToolbarItem(itemIdentifier: .Main.installHelper, icon: .wrenchAndScrewdriver).then {
        $0.label = "Install Helper"
    }

    let mcpStatusItem = MCPStatusToolbarItem().then {
        $0.label = "MCP Status"
    }

    let addEditorItem = AddEditorToolbarItem()

    let activityItem = ActivityToolbarItem()

    /// The runtime source pickers of both styles — the one in the middle of the toolbar and the one in
    /// the activity capsule — which show the same source and open the same list.
    var runtimeSourcePickers: [RuntimeSourcePicker] {
        [switchSourceItem.picker] + (activityItem.activityView.sourcePicker.map { [$0] } ?? [])
    }

    init(delegate: Delegate) {
        self.delegate = delegate
        self.toolbar = NSToolbar()
        super.init()

        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        // Before the toolbar goes into the window: the capsule's width ratio takes effect at the
        // toolbar's next layout, and lays nothing out by itself.
        updateCenteredItem()
    }

    /// Shows the toolbar in the style `activityStyle` stands for on this system, changing over the
    /// items of a toolbar already in a window.
    func apply(activityStyle: Settings.ToolbarActivityStyle) {
        let resolvedStyle = activityStyle.resolved
        guard resolvedStyle != self.activityStyle else { return }
        self.activityStyle = resolvedStyle
        updateCenteredItem()
        // Diffed by AppKit against the items already there, so the ones both styles have stay put.
        if hasProvidedItems {
            toolbar.itemIdentifiers = defaultItemIdentifiers
        }
    }

    /// The capsule in the middle, as wide as Xcode 26 makes it; the runtime source picker at its own
    /// width, where Xcode 27 puts its scheme and run destination; or, in the classic toolbar, nothing
    /// in the middle.
    private func updateCenteredItem() {
        switch activityStyle {
        case .capsule:
            toolbar.centeredItemIdentifiers = [.Main.activity]
            toolbar.box.preferredCenteredItemWidthRatio = Self.activityCapsuleWidthRatio
        case .windowTitle:
            toolbar.centeredItemIdentifiers = [.Main.switchSource]
            toolbar.box.preferredCenteredItemWidthRatio = Self.noCenteredItemWidthRatio
        case .classic, .automatic:
            // `automatic` never gets here: the style is resolved.
            toolbar.centeredItemIdentifiers = []
            toolbar.box.preferredCenteredItemWidthRatio = Self.noCenteredItemWidthRatio
        }
    }

    /// In Xcode's styles the centered item stands between two flexible spaces: the capsule, which holds
    /// the runtime source picker as Xcode 26's holds its scheme picker, or in Xcode 27's style the picker
    /// itself. The classic toolbar is the one from before them: the title, then the runtime source
    /// pop-up just before the trailing buttons.
    private var defaultItemIdentifiers: [NSToolbarItem.Identifier] {
        let middleIdentifiers: [NSToolbarItem.Identifier] = switch activityStyle {
        case .capsule:
            [.Main.title, .flexibleSpace, .Main.activity, .flexibleSpace]
        case .windowTitle:
            [.Main.activityTitle, .flexibleSpace, .Main.switchSource, .flexibleSpace]
        case .classic, .automatic:
            [.Main.title, .flexibleSpace, .Main.switchSourcePopUp]
        }
        return [
            .toggleSidebar,
            .Main.sidebarBack,
            .flexibleSpace,
            .sidebarTrackingSeparator,
            .Main.navigation,
        ] + middleIdentifiers + [
            .Main.attach,
            .Main.loadFrameworks,
            .Main.generationOptions,
            .Main.save,
            .Main.share,
            .Main.mcpStatus,
            // Last in the editor area's part of the toolbar, where Xcode 27.2's default toolbar puts its
            // Add Editor item: after it Xcode has only EditorOptions and EditorMode, which RuntimeViewer has not.
            .Main.addEditor,
            .inspectorTrackingSeparator,
            .flexibleSpace,
            .toggleInspector,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        hasProvidedItems = true
        return defaultItemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .Main.sidebarBack,
            .Main.navigation,
            .Main.title,
            .Main.activityTitle,
            .flexibleSpace,
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .inspectorTrackingSeparator,
            .toggleInspector,
            .Main.share,
            .Main.save,
            .Main.switchSource,
            .Main.switchSourcePopUp,
            .Main.generationOptions,
            .Main.loadFrameworks,
            .Main.attach,
            .Main.mcpStatus,
            .Main.activity,
            .Main.addEditor,
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .Main.sidebarBack:
            return sidebarBackItem
        case .Main.navigation:
            return navigationItem
        case .Main.title:
            return titleItem
        case .Main.activityTitle:
            return activityTitleItem
        case .Main.share:
            return sharingServicePickerItem
        case .Main.save:
            return saveItem
        case .Main.switchSource:
            return switchSourceItem
        case .Main.switchSourcePopUp:
            return switchSourcePopUpItem
        case .Main.generationOptions:
            return generationOptionsItem
        case .Main.loadFrameworks:
            return loadFrameworksItem
        case .Main.installHelper:
            return installHelperItem
        case .Main.attach:
            return attachItem
        case .Main.mcpStatus:
            return mcpStatusItem
        case .Main.activity:
            return activityItem
        case .Main.addEditor:
            return addEditorItem
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
        static let navigation: NSToolbarItem.Identifier = "navigation"
        static let navigationPrevious: NSToolbarItem.Identifier = "navigationPrevious"
        static let navigationNext: NSToolbarItem.Identifier = "navigationNext"
        static let title: NSToolbarItem.Identifier = "title"
        static let activityTitle: NSToolbarItem.Identifier = "activityTitle"
        static let share: NSToolbarItem.Identifier = "share"
        static let save: NSToolbarItem.Identifier = "save"
        static let switchSource: NSToolbarItem.Identifier = "switchSource"
        static let switchSourcePopUp: NSToolbarItem.Identifier = "switchSourcePopUp"
        static let generationOptions: NSToolbarItem.Identifier = "generationOptions"
        static let loadFrameworks: NSToolbarItem.Identifier = "loadFrameworks"
        static let installHelper: NSToolbarItem.Identifier = "installHelper"
        static let helperStatus: NSToolbarItem.Identifier = "helperStatus"
        static let attach: NSToolbarItem.Identifier = "attach"
        static let mcpStatus: NSToolbarItem.Identifier = "mcpStatus"
        static let activity: NSToolbarItem.Identifier = "activity"
        static let addEditor: NSToolbarItem.Identifier = "addEditor"
    }
}
