import AppKit
import Foundation
import Testing
@testable import RuntimeViewerUI

/// `PopUpPathControl`, Xcode's `DVTPathControl` rebuilt: where the components go, how a squeezed path
/// gives way, what the pointer highlights, the menu a component opens and what choosing from it
/// sends, and keyboard and accessibility access. Every expected measurement is DVTKit's, read out
/// of Xcode 27.0 — proposal `draft-find-navigator` §4.2.
///
/// Component frames are read the way VoiceOver reads them, from the accessibility elements; the
/// highlight from what the control draws. Menus go through the control's `menuPresenter`, since a
/// menu's tracking loop cannot run in a test.
@Suite("PopUpPathControl", .serialized)
@MainActor
struct PopUpPathControlTests {
    private static let modes = ["Text", "Regular Expression", "Ancestor Types", "Descendent Types", "Conforming Types", "Members"]

    private static let matchStyles = ["Containing", "Matching Word", "Starting With", "Ending With"]

    /// `Find ▸ Text ▸ Containing` as the Find navigator builds it: `Find` without a menu.
    private static func findNavigatorComponents() -> [PopUpPathControl.Component] {
        [
            PopUpPathControl.Component(title: "Find"),
            PopUpPathControl.Component(title: "Text", value: "Text", menuItems: modes.map { PopUpPathControl.MenuItem(title: $0, value: $0) }),
            PopUpPathControl.Component(title: "Containing", value: "Containing", menuItems: matchStyles.map { PopUpPathControl.MenuItem(title: $0, value: $0) }),
        ]
    }

    private static func plainComponents(_ titles: [String]) -> [PopUpPathControl.Component] {
        titles.map { title in
            PopUpPathControl.Component(title: title, value: title, menuItems: [PopUpPathControl.MenuItem(title: title, value: title)])
        }
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11)]).size().width
    }

    // MARK: - Layout

    @Test("each component spans its title, 7 points before the first title or 2 before the others, and a 14-point slot after it")
    func componentsSpanTheirTitles() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        let frames = fixture.componentFrames()
        let margins: [CGFloat] = [7, 2, 2]
        try #require(frames.count == 3)
        for (index, title) in ["Find", "Text", "Containing"].enumerated() {
            let width = margins[index] + Self.titleWidth(title) + 14
            #expect(frames[index].width >= width && frames[index].width < width + 1, "\(title): \(frames[index].width) for \(width)")
            #expect(frames[index].height == 17)
        }
        #expect(frames[0].minX == 0)
        #expect(frames[1].minX == frames[0].maxX)
        #expect(frames[2].minX == frames[1].maxX)
    }

    @Test("a squeezed path levels its middle components down from the widest, and leaves the others alone")
    func squeezedPathLevelsTheMiddleComponents() throws {
        let titles = ["Find", "Regular Expression", "Text", "Conforming Types", "Containing"]
        let fullWidths = Fixture(width: 1000, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }
        let total = fullWidths.reduce(0, +)

        // Less than the widest middle component exceeds the next one by: it alone gives way.
        let widestOnly = Fixture(width: total - 20, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }
        #expect(abs(widestOnly[1] - (fullWidths[1] - 20)) < 0.01)
        #expect([widestOnly[0], widestOnly[2], widestOnly[3], widestOnly[4]] == [fullWidths[0], fullWidths[2], fullWidths[3], fullWidths[4]])

        // More than that: the two middle components end up level, and share the rest.
        let gap = fullWidths[1] - fullWidths[2]
        let levelled = Fixture(width: total - gap - 6, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }
        #expect(abs(levelled[1] - (fullWidths[2] - 3)) < 0.01)
        #expect(abs(levelled[2] - (fullWidths[2] - 3)) < 0.01)
        #expect([levelled[0], levelled[3], levelled[4]] == [fullWidths[0], fullWidths[3], fullWidths[4]])
    }

    @Test("past the middle, the first component gives way down to 37 points, then the one before the last; the last never does")
    func squeezedPathShrinksTheFirstThenTheOneBeforeTheLast() throws {
        let titles = ["Find", "Conforming Types", "Containing"]
        let fullWidths = Fixture(width: 1000, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }
        let firstShrinkableWidth = fullWidths[0] - 37
        try #require(firstShrinkableWidth > 0 && firstShrinkableWidth < 30)

        let widths = Fixture(width: fullWidths.reduce(0, +) - 30, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }

        #expect(widths[0] == 37)
        #expect(abs(widths[1] - (fullWidths[1] - (30 - firstShrinkableWidth))) < 0.01)
        #expect(widths[2] == fullWidths[2])
    }

    @Test("the component that crosses the trailing edge is clipped, and the ones after it are not shown")
    func componentsPastTheTrailingEdgeAreClippedOrHidden() throws {
        // Fully squeezed, the first three take their minimum widths: 37, 32 and 32 points.
        let fixture = Fixture(width: 37 + 32 + 10, components: Self.plainComponents(["Find", "Text", "Containing", "Members"]))
        defer { fixture.tearDown() }

        let frames = fixture.componentFrames()

        #expect(frames.map(\.width) == [37, 32, 10, 0])
        #expect(frames[2].minX == 69)
    }

    // MARK: - Hover

    @Test("the pointer highlights the component under it and nothing else")
    func pointerHighlightsOnlyTheComponentUnderIt() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }
        let componentFrame = fixture.componentFrames()[1]

        let unhovered = fixture.render()
        fixture.movePointer(toComponentAt: 1)
        let hovered = fixture.render()

        let changedInside = Fixture.changedPixelCount(between: unhovered, and: hovered, in: componentFrame, of: fixture.pathControl)
        let changedEverywhere = Fixture.changedPixelCount(between: unhovered, and: hovered, in: fixture.pathControl.bounds, of: fixture.pathControl)
        #expect(changedInside > 0)
        #expect(changedEverywhere == changedInside)

        fixture.movePointerOutOfControl()
        let left = fixture.render()
        #expect(Fixture.changedPixelCount(between: unhovered, and: left, in: fixture.pathControl.bounds, of: fixture.pathControl) == 0)
    }

    @Test("a component without a menu does not highlight")
    func componentWithoutMenuDoesNotHighlight() {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        let unhovered = fixture.render()
        fixture.movePointer(toComponentAt: 0)

        #expect(Fixture.changedPixelCount(between: unhovered, and: fixture.render(), in: fixture.pathControl.bounds, of: fixture.pathControl) == 0)
    }

    @Test("a squeezed component widens to its full width under the pointer, and gives it back when the pointer leaves")
    func squeezedComponentWidensUnderThePointer() throws {
        let titles = ["Find", "Conforming Types", "Containing"]
        let fullWidths = Fixture(width: 1000, components: Self.plainComponents(titles)).tearingDown { $0.componentFrames().map(\.width) }
        let fixture = Fixture(width: fullWidths.reduce(0, +) - 30, components: Self.plainComponents(titles))
        defer { fixture.tearDown() }
        let squeezedWidth = fixture.componentFrames()[0].width
        try #require(squeezedWidth < fullWidths[0])

        fixture.movePointer(toComponentAt: 0)
        Fixture.runAnimations()
        #expect(fixture.componentFrames()[0].width == fullWidths[0])

        fixture.movePointerOutOfControl()
        Fixture.runAnimations()
        #expect(fixture.componentFrames()[0].width == squeezedWidth)
    }

    // MARK: - Menus

    @Test("a press opens the component's peers with the current one laid over the component, unchecked")
    func pressOpensPeersOverTheComponent() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }
        let componentFrame = fixture.componentFrames()[1]

        fixture.press(componentAt: 1)

        let presentation = try #require(fixture.presentedMenus.only)
        #expect(presentation.menu.items.map(\.title) == Self.modes)
        #expect(presentation.menu.items.allSatisfy { $0.state == .off })
        #expect(presentation.menu.font?.pointSize == 11)
        #expect(presentation.positioningItem?.title == "Text")
        // 14 points left of the component, 2 less without an icon; 11 points above its middle.
        #expect(presentation.location == NSPoint(x: componentFrame.minX - 12, y: componentFrame.midY - 11))
    }

    @Test("the first component's menu goes 5 points further right, onto its wider margin")
    func firstComponentMenuFollowsItsMargin() throws {
        let fixture = Fixture(width: 400, components: Self.plainComponents(["Text", "Containing"]))
        defer { fixture.tearDown() }
        let componentFrame = fixture.componentFrames()[0]

        fixture.press(componentAt: 0)

        let presentation = try #require(fixture.presentedMenus.only)
        #expect(presentation.location == NSPoint(x: componentFrame.minX - 7, y: componentFrame.midY - 11))
    }

    @Test("a component without a menu opens nothing")
    func componentWithoutMenuOpensNothing() {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        fixture.press(componentAt: 0)

        #expect(fixture.presentedMenus.isEmpty)
    }

    @Test("a disabled control opens nothing")
    func disabledControlOpensNothing() {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }
        fixture.pathControl.isEnabled = false

        fixture.press(componentAt: 1)

        #expect(fixture.presentedMenus.isEmpty)
    }

    @Test("an item that starts a group gets a separator above it")
    func groupStartGetsSeparator() throws {
        let menuItems = [
            PopUpPathControl.MenuItem(title: "Containing", value: 0),
            PopUpPathControl.MenuItem(title: "Ending With", value: 1),
            PopUpPathControl.MenuItem(title: "Regular Expression", value: 2, isPrecededBySeparator: true),
        ]
        let fixture = Fixture(width: 400, components: [PopUpPathControl.Component(title: "Containing", value: 0, menuItems: menuItems)])
        defer { fixture.tearDown() }

        fixture.press(componentAt: 0)

        let menu = try #require(fixture.presentedMenus.only?.menu)
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, true, false])
        #expect(menu.items.last?.title == "Regular Expression")
    }

    @Test("choosing an item reports the component and the item's value through the control's action")
    func choosingAnItemSendsTheAction() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        fixture.press(componentAt: 2)
        let menu = try #require(fixture.presentedMenus.only?.menu)
        menu.performActionForItem(at: 1)

        #expect(fixture.actionRecorder.senders.count == 1)
        #expect(fixture.actionRecorder.senders.first as? PopUpPathControl === fixture.pathControl)
        #expect(fixture.pathControl.lastSelection?.componentIndex == 2)
        #expect(fixture.pathControl.lastSelection?.value == AnyHashable("Matching Word"))
    }

    // MARK: - Keyboard

    @Test("arrow keys move the focus ring between the components that have a menu")
    func arrowKeysMoveFocusBetweenComponents() {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }
        let frames = fixture.componentFrames()

        fixture.pathControl.moveRight(nil)
        #expect(fixture.pathControl.focusRingMaskBounds == frames[1])
        fixture.pathControl.moveRight(nil)
        #expect(fixture.pathControl.focusRingMaskBounds == frames[2])
        fixture.pathControl.moveRight(nil)
        #expect(fixture.pathControl.focusRingMaskBounds == frames[2])
        fixture.pathControl.moveLeft(nil)
        #expect(fixture.pathControl.focusRingMaskBounds == frames[1])
        fixture.pathControl.moveLeft(nil)
        #expect(fixture.pathControl.focusRingMaskBounds == frames[1])
    }

    @Test("Space opens the focused component's menu")
    func spaceOpensFocusedComponentMenu() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        fixture.pathControl.moveRight(nil)
        fixture.pathControl.moveRight(nil)
        fixture.pressSpace()

        let presentation = try #require(fixture.presentedMenus.only)
        #expect(presentation.positioningItem?.title == "Containing")
    }

    @Test("a click does not take keyboard focus")
    func clickDoesNotTakeFocus() {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        #expect(fixture.pathControl.acceptsFirstResponder == false)
    }

    // MARK: - Accessibility

    @Test("accessibility sees a list of pop-up buttons titled after the components, and pressing one opens its menu")
    func accessibilitySeesPopUpButtons() throws {
        let fixture = Fixture(width: 400, components: Self.findNavigatorComponents())
        defer { fixture.tearDown() }

        let elements = try #require(fixture.pathControl.accessibilityChildren() as? [NSAccessibilityElement])

        #expect(fixture.pathControl.accessibilityRole() == .list)
        #expect(elements.map { $0.accessibilityRole() } == [.staticText, .popUpButton, .popUpButton])
        #expect(elements.map { $0.accessibilityValue() as? String } == ["Find", "Text", "Containing"])
        #expect(elements[1].accessibilityPerformPress())
        #expect(fixture.presentedMenus.only?.positioningItem?.title == "Text")
    }
}

// MARK: - Fixture

extension PopUpPathControlTests {
    /// A path control 17 points tall at the small size, as the Find navigator has it, in a window
    /// outside every display.
    @MainActor
    final class Fixture {
        typealias MenuPresentation = (menu: NSMenu, positioningItem: NSMenuItem?, location: NSPoint)

        let window: NSWindow
        let pathControl: PopUpPathControl
        let actionRecorder = ActionRecorder()
        private(set) var presentedMenus: [MenuPresentation] = []

        init(width: CGFloat, components: [PopUpPathControl.Component]) {
            // A control sends its action through `NSApp`.
            _ = NSApplication.shared
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: width, height: 17),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 17))
            window.contentView = contentView
            pathControl = PopUpPathControl(frame: NSRect(x: 0, y: 0, width: width, height: 17))
            pathControl.controlSize = .small
            contentView.addSubview(pathControl)
            pathControl.menuPresenter = { [weak self] menu, positioningItem, location, _ in
                guard let self else { return }
                presentedMenus.append((menu, positioningItem, location))
            }
            pathControl.target = actionRecorder
            pathControl.action = #selector(ActionRecorder.recordAction(_:))
            pathControl.components = components
            window.orderFrontRegardless()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        /// Runs `body` on the fixture and takes it down.
        func tearingDown<Result>(_ body: (Fixture) -> Result) -> Result {
            defer { tearDown() }
            return body(self)
        }

        /// Each component's frame as the control reports it to accessibility.
        func componentFrames() -> [NSRect] {
            (pathControl.accessibilityChildren() as? [NSAccessibilityElement] ?? []).map { $0.accessibilityFrameInParentSpace() }
        }

        func movePointer(toComponentAt index: Int) {
            let frame = componentFrames()[index]
            pathControl.mouseMoved(with: mouseEvent(.mouseMoved, at: NSPoint(x: frame.midX, y: frame.midY)))
        }

        func movePointerOutOfControl() {
            pathControl.mouseExited(with: mouseEvent(.mouseMoved, at: NSPoint(x: pathControl.bounds.maxX + 50, y: 8)))
        }

        func press(componentAt index: Int) {
            let frame = componentFrames()[index]
            pathControl.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: frame.midX, y: frame.midY)))
        }

        func pressSpace() {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            )
            if let event {
                pathControl.keyDown(with: event)
            }
        }

        func render() -> NSBitmapImageRep {
            let bitmap = pathControl.bitmapImageRepForCachingDisplay(in: pathControl.bounds)!
            pathControl.cacheDisplay(in: pathControl.bounds, to: bitmap)
            return bitmap
        }

        /// Lets the hover animation, 0.2 seconds long, run to its end.
        static func runAnimations() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }

        /// How many pixels inside `rect` — in the control's flipped coordinates, which bitmap rows
        /// follow top to bottom — differ between two renderings.
        static func changedPixelCount(between first: NSBitmapImageRep, and second: NSBitmapImageRep, in rect: NSRect, of view: NSView) -> Int {
            let scale = CGFloat(first.pixelsWide) / view.bounds.width
            let columns = Int((rect.minX * scale).rounded(.down)) ..< min(first.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
            let rows = Int((rect.minY * scale).rounded(.down)) ..< min(first.pixelsHigh, Int((rect.maxY * scale).rounded(.up)))
            var firstSamples = [Int](repeating: 0, count: first.samplesPerPixel)
            var secondSamples = [Int](repeating: 0, count: second.samplesPerPixel)
            var changedPixelCount = 0
            for row in rows {
                for column in columns {
                    first.getPixel(&firstSamples, atX: column, y: row)
                    second.getPixel(&secondSamples, atX: column, y: row)
                    if firstSamples != secondSamples {
                        changedPixelCount += 1
                    }
                }
            }
            return changedPixelCount
        }

        private func mouseEvent(_ type: NSEvent.EventType, at pointInControl: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: pathControl.convert(pointInControl, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .leftMouseDown ? 1 : 0,
                pressure: type == .leftMouseDown ? 1 : 0
            )!
        }
    }

    @MainActor
    final class ActionRecorder: NSObject {
        private(set) var senders: [Any] = []

        @objc func recordAction(_ sender: Any?) {
            senders.append(sender as Any)
        }
    }
}

extension Array {
    /// The element of a one-element array; `nil` for any other count.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
