import AppKit
import Foundation
import Testing
import RuntimeViewerUI

/// Regression suite for a long toolbar title pushing the toolbar's centered item aside.
///
/// History: when a toolbar section has a centered item, NSToolbar lays the section out in three groups —
/// the items before the centered item, the item itself and the items after it — and shares the room
/// they leave among the three, each group up to the widest it can be
/// (`-[NSBarLayout _centerRectGivenItems:leadingItems:trailingItems:inRect:]`, the same on macOS 27.0 and
/// 27.2). The centered item stays midway between the sidebar and the inspector only while the group
/// before it ends short of where it would start; past that it slides towards the items after it. The
/// title's widest was the width of its text, so a long title or subtitle took all of that room, and the
/// runtime source picker — Xcode 26's activity capsule in the other style — was pushed against the
/// buttons after it. Background:
/// `Documentations/ResolvedIssues/2026-11-05-long-toolbar-title-pushed-the-centered-item-aside.md`.
///
/// The fixture is shaped like the main window: a sidebar, the content and an inspector, and above the
/// content the navigation control, the title, a flexible space, the centered item, a flexible space and
/// four buttons, in a unified toolbar.
@Suite("ToolbarCenteredItem", .serialized)
@MainActor
struct ToolbarCenteredItemTests {
    /// The two toolbar styles that center an item.
    enum Style: CaseIterable, Sendable, CustomTestStringConvertible {
        /// Xcode 27's: the title with its activity ring, and the runtime source picker in the middle at
        /// its own width.
        case windowTitle

        /// Xcode 26's: the plain title, and the activity capsule in the middle at 40 % of the toolbar.
        case activityCapsule

        var testDescription: String {
            switch self {
            case .windowTitle: "Xcode 27's style"
            case .activityCapsule: "Xcode 26's style"
            }
        }
    }

    /// Which of the two labels carries the text wider than the window.
    enum LongLabel: CaseIterable, Sendable {
        case title
        case subtitle
    }

    private static let textWiderThanTheWindow = String(repeating: "__C.UITextFormattingViewControllerTextAlignment ", count: 12)

    private static let shortTitle = "UIKitCore"

    private static let shortSubtitle = "UIView"

    private static func texts(withLong longLabel: LongLabel) -> (title: String, subtitle: String) {
        (
            title: longLabel == .title ? textWiderThanTheWindow : shortTitle,
            subtitle: longLabel == .subtitle ? textWiderThanTheWindow : shortSubtitle
        )
    }

    @Test("with a short title the centered item sits midway between the sidebar and the inspector", arguments: Style.allCases)
    func shortTitleLeavesTheCenteredItemInTheMiddle(style: Style) throws {
        let fixture = Fixture(style: style)
        defer { fixture.tearDown() }

        fixture.show(title: Self.shortTitle, subtitle: Self.shortSubtitle)

        let centeredItemFrame = try #require(fixture.centeredItemFrame())
        let middleX = fixture.middleBetweenTheSidebarAndTheInspector()
        #expect(
            abs(centeredItemFrame.midX - middleX) <= 1.5,
            "the centered item's middle is at \(centeredItemFrame.midX) pt, midway between the panes' edges is \(middleX) pt"
        )
    }

    @Test(
        "a long title or subtitle leaves the centered item where a short one does and is cut short before it",
        arguments: Style.allCases, LongLabel.allCases
    )
    func longLabelLeavesTheCenteredItemInPlace(style: Style, longLabel: LongLabel) throws {
        let fixture = Fixture(style: style)
        defer { fixture.tearDown() }

        fixture.show(title: Self.shortTitle, subtitle: Self.shortSubtitle)
        let shortTitleFrame = try #require(fixture.centeredItemFrame())

        let texts = Self.texts(withLong: longLabel)
        fixture.show(title: texts.title, subtitle: texts.subtitle)
        let longTitleFrame = try #require(fixture.centeredItemFrame())

        #expect(
            abs(longTitleFrame.midX - shortTitleFrame.midX) <= 0.5,
            "the centered item's middle moved from \(shortTitleFrame.midX) pt to \(longTitleFrame.midX) pt"
        )
        #expect(
            abs(longTitleFrame.width - shortTitleFrame.width) <= 0.5,
            "the centered item went from \(shortTitleFrame.width) pt to \(longTitleFrame.width) pt wide"
        )

        let longTextLabel = try #require(fixture.shownTitleLabels().first { $0.stringValue == Self.textWiderThanTheWindow })
        #expect(
            longTextLabel.frame.width < longTextLabel.intrinsicContentSize.width,
            "not cut short: \(longTextLabel.frame.width) pt shown of \(longTextLabel.intrinsicContentSize.width) pt"
        )
        let titleContentFrame = try #require(fixture.titleContentFrame())
        #expect(
            titleContentFrame.maxX <= longTitleFrame.minX,
            "the title runs to \(titleContentFrame.maxX) pt, past the centered item's leading edge at \(longTitleFrame.minX) pt"
        )
    }

    @Test("a click between the title and the centered item goes to neither of them", arguments: Style.allCases)
    func clickBetweenTheTitleAndTheCenteredItemMissesBoth(style: Style) throws {
        let fixture = Fixture(style: style)
        defer { fixture.tearDown() }

        fixture.show(title: Self.shortTitle, subtitle: Self.shortSubtitle)

        let titleContentFrame = try #require(fixture.titleContentFrame())
        let centeredItemFrame = try #require(fixture.centeredItemFrame())
        try #require(
            centeredItemFrame.minX - titleContentFrame.maxX > 20,
            "only \(centeredItemFrame.minX - titleContentFrame.maxX) pt between the title and the centered item"
        )
        let point = NSPoint(x: (titleContentFrame.maxX + centeredItemFrame.minX) / 2, y: titleContentFrame.midY)
        let hitView = fixture.hitView(atWindowPoint: point)
        let titleItemView = try #require(fixture.titleItem.view)

        let hitViewDescription = hitView.map { "\(type(of: $0))" } ?? "nothing"
        #expect(hitView.map { !$0.isDescendant(of: titleItemView) } ?? true, "the click hit \(hitViewDescription), in the title item")
        #expect(hitView.map { !$0.isDescendant(of: fixture.centeredItemView) } ?? true, "the click hit \(hitViewDescription), in the centered item")
    }
}

// MARK: - Fixture

extension ToolbarCenteredItemTests {
    /// A 1400-point window outside every display with a 200-point sidebar and a 200-point inspector,
    /// whose toolbar holds the middle of the main window's toolbar above the content: room for every
    /// item and a short title beside the centered item at the width it wants, not for text wider than
    /// the window.
    @MainActor
    final class Fixture: NSObject, NSToolbarDelegate {
        static let navigationItemIdentifier = NSToolbarItem.Identifier("navigation")

        static let titleItemIdentifier = NSToolbarItem.Identifier("title")

        static let centeredItemIdentifier = NSToolbarItem.Identifier("centered")

        static let buttonItemIdentifiers = (1 ... 4).map { NSToolbarItem.Identifier("button\($0)") }

        static let windowWidth: CGFloat = 1400

        static let windowHeight: CGFloat = 600

        static let sidebarWidth: CGFloat = 200

        static let inspectorWidth: CGFloat = 200

        /// The capsule's share of the toolbar's width, as `MainToolbarController` sets it.
        static let activityCapsuleWidthRatio: CGFloat = 0.4

        static let sourceTitle = "My Mac (Mac Catalyst)"

        let window: NSWindow

        let toolbar = NSToolbar()

        let splitViewController = NSSplitViewController()

        let titleItem: TitleToolbarItem

        let centeredItemView: NSView

        var splitView: NSSplitView { splitViewController.splitView }

        init(style: Style) {
            switch style {
            case .windowTitle:
                titleItem = TitleToolbarItem(itemIdentifier: Self.titleItemIdentifier, showsActivity: true)
                let pickerView = RuntimeSourcePickerToolbarView()
                pickerView.picker.title = Self.sourceTitle
                centeredItemView = pickerView
            case .activityCapsule:
                titleItem = TitleToolbarItem(itemIdentifier: Self.titleItemIdentifier)
                let activityView = ToolbarActivityView(showsSourcePicker: true)
                activityView.sourcePicker?.title = Self.sourceTitle
                centeredItemView = activityView
            }
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: Self.windowWidth, height: Self.windowHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            super.init()

            let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.makePaneViewController())
            sidebarItem.minimumThickness = Self.sidebarWidth
            sidebarItem.holdingPriority = NSLayoutConstraint.Priority(261)
            let contentItem = NSSplitViewItem(viewController: Self.makePaneViewController())
            contentItem.holdingPriority = NSLayoutConstraint.Priority(250)
            let inspectorItem = NSSplitViewItem(inspectorWithViewController: Self.makePaneViewController())
            inspectorItem.minimumThickness = Self.inspectorWidth
            inspectorItem.holdingPriority = NSLayoutConstraint.Priority(261)
            splitViewController.splitViewItems = [sidebarItem, contentItem, inspectorItem]

            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.centeredItemIdentifiers = [Self.centeredItemIdentifier]
            if style == .activityCapsule {
                // Before the toolbar goes into the window, as `MainToolbarController` sets it.
                toolbar.box.preferredCenteredItemWidthRatio = Self.activityCapsuleWidthRatio
            }

            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            // The window takes its content view controller's view's size, so that view needs one first.
            splitViewController.view.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
            window.contentViewController = splitViewController
            window.toolbar = toolbar
            window.orderFrontRegardless()
            layoutAndDisplay()

            splitView.setPosition(Self.sidebarWidth, ofDividerAt: 0)
            splitView.setPosition(splitView.bounds.width - Self.inspectorWidth - splitView.dividerThickness, ofDividerAt: 1)
            layoutAndDisplay()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        func show(title: String, subtitle: String) {
            titleItem.displayTitle = title
            titleItem.displaySubtitle = subtitle
            layoutAndDisplay()
        }

        /// What the window does at the end of a run loop turn.
        func layoutAndDisplay() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }

        /// The centered item's view in window coordinates; `nil` when it is not in the window.
        func centeredItemFrame() -> NSRect? {
            guard centeredItemView.window === window else { return nil }
            return centeredItemView.convert(centeredItemView.bounds, to: nil)
        }

        /// Midway between the sidebar's trailing edge and the inspector's leading edge, in window
        /// coordinates.
        func middleBetweenTheSidebarAndTheInspector() -> CGFloat {
            let sidebarView = splitView.arrangedSubviews[0]
            let inspectorView = splitView.arrangedSubviews[2]
            let sidebarEnd = splitView.convert(NSPoint(x: sidebarView.frame.maxX, y: 0), to: nil).x
            let inspectorStart = splitView.convert(NSPoint(x: inspectorView.frame.minX, y: 0), to: nil).x
            return (sidebarEnd + inspectorStart) / 2
        }

        /// The labels the title item has on screen, as laid out.
        func shownTitleLabels() -> [NSTextField] {
            guard let titleView = titleItem.view else { return [] }
            return Self.descendants(of: titleView)
                .compactMap { $0 as? NSTextField }
                .filter { label in !label.isHiddenOrHasHiddenAncestor }
        }

        /// The part of the title item that shows the title — the view holding the icon slot and the
        /// stack of labels — in window coordinates; `nil` when it is not in the window. Found from the
        /// title's label, since the activity ring holds a label of its own.
        func titleContentFrame() -> NSRect? {
            guard let label = shownTitleLabels().first(where: { $0.stringValue == titleItem.displayTitle }),
                  let contentView = label.superview?.superview,
                  contentView.window === window
            else { return nil }
            return contentView.convert(contentView.bounds, to: nil)
        }

        /// The view a click at `point` reaches, as the window finds it.
        func hitView(atWindowPoint point: NSPoint) -> NSView? {
            guard let frameView = window.contentView?.superview else { return nil }
            return frameView.hitTest(point)
        }

        private static func makePaneViewController() -> NSViewController {
            let viewController = NSViewController()
            viewController.view = NSView()
            return viewController
        }

        private static func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { subview in [subview] + descendants(of: subview) }
        }

        // MARK: - NSToolbarDelegate

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [
                .sidebarTrackingSeparator,
                Self.navigationItemIdentifier,
                Self.titleItemIdentifier,
                .flexibleSpace,
                Self.centeredItemIdentifier,
                .flexibleSpace,
            ] + Self.buttonItemIdentifiers + [
                .inspectorTrackingSeparator,
            ]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(
            _ toolbar: NSToolbar,
            itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar flag: Bool
        ) -> NSToolbarItem? {
            switch itemIdentifier {
            case Self.titleItemIdentifier:
                return titleItem
            case Self.navigationItemIdentifier:
                let navigationItem = NSToolbarItem(itemIdentifier: itemIdentifier)
                navigationItem.isNavigational = true
                let segmentedControl = NSSegmentedControl()
                segmentedControl.segmentCount = 2
                segmentedControl.trackingMode = .momentary
                segmentedControl.setImage(NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil), forSegment: 0)
                segmentedControl.setImage(NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil), forSegment: 1)
                navigationItem.view = segmentedControl
                return navigationItem
            case Self.centeredItemIdentifier:
                let centeredItem = NSToolbarItem(itemIdentifier: itemIdentifier)
                centeredItem.label = "Centered"
                centeredItem.visibilityPriority = .high
                centeredItem.view = centeredItemView
                return centeredItem
            case let identifier where Self.buttonItemIdentifiers.contains(identifier):
                let buttonItem = NSToolbarItem(itemIdentifier: identifier)
                buttonItem.label = identifier.rawValue
                let button = NSButton(title: "", target: nil, action: nil)
                button.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
                button.bezelStyle = .toolbar
                buttonItem.view = button
                return buttonItem
            default:
                return nil
            }
        }
    }
}
