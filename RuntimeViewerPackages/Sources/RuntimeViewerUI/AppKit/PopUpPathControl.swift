#if os(macOS)

import AppKit
import UIFoundation

/// Xcode's path control, `DVTPathControl` (DVTKit), rebuilt the way Xcode's Find navigator sets it
/// up for its `Find ▸ Text ▸ Containing` row: flat highlights, a menu per component, one component
/// chosen at a time.
///
/// Every component is a pop-up — its menu opens with the current item laid over it, as an
/// `NSPopUpButton`'s does, and accessibility presents it as one — hence the name.
///
/// Xcode does not use `NSPathControl` there. DVTKit carries a private copy of it
/// (`_DVTNSPathControl`, `_DVTNSPathCell`, `_DVTNSPathComponentCell`) and draws everything itself:
/// the highlight under the pointer, the chevron that turns into a pop-up indicator, the menu laid
/// over the component, the title that fades out instead of being truncated. Each rule below names
/// the DVTKit method it was read from, in Xcode 27.0; the measurements are collected in the Find
/// navigator proposal, `draft-find-navigator` §4.2.
///
/// The control only reports choices: picking a menu item sets `lastSelection` and sends the
/// action, and the owner answers by setting new `components`.
public final class PopUpPathControl: Control {
    // MARK: - Model

    /// One component of the path: its title, and the menu of its peers.
    public struct Component: Equatable {
        public var title: String

        /// Replaces the colour the control picks for the title. Xcode's Find navigator accents a
        /// choice other than the default this way.
        public var titleColor: NSColor?

        /// What the component shows. The menu item with the same value is laid over the component
        /// when its menu opens.
        public var value: AnyHashable?

        /// The component's peers, which its menu lists. A component without any is plain text: it
        /// neither highlights under the pointer nor opens a menu.
        public var menuItems: [MenuItem]

        public init(title: String, titleColor: NSColor? = nil, value: AnyHashable? = nil, menuItems: [MenuItem] = []) {
            self.title = title
            self.titleColor = titleColor
            self.value = value
            self.menuItems = menuItems
        }

        var isInteractive: Bool { !menuItems.isEmpty }
    }

    /// One item of a component's menu.
    public struct MenuItem: Equatable {
        public var title: String

        public var value: AnyHashable

        public var isEnabled: Bool

        /// Puts a separator above the item, where DVTKit puts one: wherever an item's group differs
        /// from the one before it.
        public var isPrecededBySeparator: Bool

        public init(title: String, value: AnyHashable, isEnabled: Bool = true, isPrecededBySeparator: Bool = false) {
            self.title = title
            self.value = value
            self.isEnabled = isEnabled
            self.isPrecededBySeparator = isPrecededBySeparator
        }
    }

    /// A choice made in a component's menu.
    public struct Selection: Equatable {
        public let componentIndex: Int

        public let value: AnyHashable
    }

    public var components: [Component] = [] {
        didSet {
            guard components != oldValue else { return }
            componentsDidChange()
        }
    }

    /// The last choice made in a menu, set right before the control sends its action.
    public private(set) var lastSelection: Selection?

    // MARK: - Measurements

    private enum Metrics {
        /// `-[DVTPathComponentCell _leftDividerWidth]` with flat highlights: 7 points before the
        /// first title (`padsFirstItem`, on unless turned off), 2 before the others.
        static let firstComponentLeadingMargin: CGFloat = 7
        static let leadingMargin: CGFloat = 2

        /// `-[DVTPathComponentCell _rightDividerWidth]` with flat highlights: the slot after every
        /// component, the last one included, that the chevron is centred in.
        static let dividerWidth: CGFloat = 14

        /// `+[DVTPathComponentCell _iconSizeForControlSize:]` below the large size. The components
        /// here carry no icon, but DVTKit still counts one in a component's minimum width and in
        /// how far right a chevron has to sit to be drawn.
        static let iconWidth: CGFloat = 16

        /// `-[DVTPathComponentCell drawInteriorWithFrame:inView:]`: no title is drawn into less
        /// room than this, the title may run 2 points into the divider's slot, and a title that
        /// overflows its room by more than the tolerance fades out instead.
        static let minimumTitleRoom: CGFloat = 3
        static let titleRoomIntoDivider: CGFloat = 2
        static let titleOverflowTolerance: CGFloat = 0.9

        /// `-[DVTPathComponentCell _drawGradientMaskForTitleRect:]`
        static let titleFadeWidth: CGFloat = 10

        /// `-[DVTPathComponentCell _drawHoveredInFrame:]`
        static let highlightCornerRadius: CGFloat = 4

        /// `-[DVTPathCell popUpMenuForComponentCell:inRect:ofView:withMenuItems:]`: the menu's
        /// current item goes 14 points left of the component — 2 points less without an icon, and
        /// another 5 less for the first component — and 11 points above its middle, so that the
        /// item's title lands on the component's.
        static let menuHorizontalOffset: CGFloat = -14 + 2
        static let firstComponentMenuHorizontalOffset: CGFloat = -14 + 2 + 4 + 1
        static let menuVerticalOffset: CGFloat = -11

        /// `-[_DVTNSPathCell _createHoverChangeAnimation]`
        static let hoverAnimationDuration: TimeInterval = 0.2

        /// `-[DVTPathCell sizeWantedForFrame:inView:]`
        static let intrinsicWidthPadding: CGFloat = 2
    }

    // MARK: - State

    /// The component under the pointer; only a component with a menu gets one.
    private var hoveredComponentIndex: Int?

    /// The component keyboard focus is on, while the control is first responder.
    private var keyFocusedComponentIndex: Int?

    /// `-[_DVTNSPathComponentCell _fullWidth]`: what each component needs, aligned to the device
    /// pixel grid.
    private var fullWidths: [CGFloat] = []

    /// What each component gets once the path is fitted into the control.
    private var resizedWidths: [CGFloat] = []

    /// What each component is drawn at: its resized width, except for the hovered component,
    /// which the hover animation widens to its full width.
    private var currentWidths: [CGFloat] = []

    /// The width the widths above were fitted into; any other width fits them again.
    private var fittedWidth: CGFloat?

    private var hoverAnimation: HoverAnimation?

    private var componentAccessibilityElements: [ComponentAccessibilityElement]?

    private var windowObservations: [NSObjectProtocol] = []

    /// Shows a component's menu. Tests replace it, as a menu's tracking loop cannot run in them.
    var menuPresenter: (_ menu: NSMenu, _ positioningItem: NSMenuItem?, _ location: NSPoint, _ view: NSView) -> Void = { menu, positioningItem, location, view in
        _ = menu.popUp(positioning: positioningItem, at: location, in: view)
    }

    // MARK: - Lifecycle

    public override func setup() {
        super.setup()
        // `-[DVTPathControl initWithFrame:]`
        clipsToBounds = true
        // DVTKit keeps one tracking area per component and swaps them as the components move;
        // one area over the whole control, asking which component is under the pointer, gives the
        // same hover without depending on the order AppKit delivers one area's exit and the next
        // one's entry in.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        ))
    }

    public override var isFlipped: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// `-[DVTPathControl setControlSize:]`: the title font follows the control size.
    public override var controlSize: NSControl.ControlSize {
        didSet {
            font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        }
    }

    public override var font: NSFont? {
        didSet {
            invalidateComponentLayout()
        }
    }

    public override var isEnabled: Bool {
        didSet {
            needsDisplay = true
        }
    }

    public override var intrinsicContentSize: NSSize {
        fitComponentsIfNeeded()
        let width = fullWidths.reduce(0, +)
        return NSSize(width: width > 0 ? width + Metrics.intrinsicWidthPadding : 0, height: NSView.noIntrinsicMetric)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for observation in windowObservations {
            NotificationCenter.default.removeObserver(observation)
        }
        windowObservations = []
        if newWindow == nil {
            // `-[DVTPathControl viewWillMoveToWindow:]` resets the path cell.
            hoverAnimation?.stop()
            hoverAnimation = nil
            hoveredComponentIndex = nil
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // `-[_DVTNSPathControl _windowChangedKeyState]`: titles and chevrons are drawn differently
        // in an inactive window.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
        ]
        windowObservations = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                needsDisplay = true
            }
        }
        invalidateComponentLayout()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateComponentLayout()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Fitting

    private func componentsDidChange() {
        componentAccessibilityElements = nil
        if let keyFocusedComponentIndex, !isInteractiveComponent(at: keyFocusedComponentIndex) {
            self.keyFocusedComponentIndex = nil
        }
        invalidateComponentLayout()
        updateHoveredComponentFromPointer()
        // A new path starts every component at its resized width, the hovered one included.
        animateWidthsTowardHoverTargets()
    }

    private func invalidateComponentLayout() {
        fittedWidth = nil
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var titleFont: NSFont {
        font ?? .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
    }

    private func isInteractiveComponent(at index: Int) -> Bool {
        components.indices.contains(index) && components[index].isInteractive
    }

    private func leadingMargin(ofComponentAt index: Int) -> CGFloat {
        index == 0 ? Metrics.firstComponentLeadingMargin : Metrics.leadingMargin
    }

    /// `-[DVTPathComponentCell cellSizeForBounds:]`, aligned the way `-[_DVTNSPathComponentCell
    /// _fullWidth]` aligns it.
    private func fullWidth(ofComponentAt index: Int) -> CGFloat {
        let titleWidth = NSAttributedString(string: components[index].title, attributes: [.font: titleFont]).size().width
        let width = leadingMargin(ofComponentAt: index) + titleWidth + Metrics.dividerWidth
        return backingAlignedRect(
            NSRect(x: 0, y: 0, width: width, height: 0),
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthOutward, .alignHeightOutward]
        ).width
    }

    /// `-[DVTPathComponentCell _minWidth]`
    private func minimumWidth(ofComponentAt index: Int) -> CGFloat {
        leadingMargin(ofComponentAt: index) + Metrics.iconWidth + Metrics.dividerWidth
    }

    private func fitComponentsIfNeeded() {
        guard fittedWidth != bounds.width || currentWidths.count != components.count else { return }
        fittedWidth = bounds.width
        hoverAnimation?.stop()
        hoverAnimation = nil
        fullWidths = components.indices.map(fullWidth(ofComponentAt:))
        resizedWidths = Self.resizedWidths(
            fullWidths: fullWidths,
            minimumWidths: components.indices.map(minimumWidth(ofComponentAt:)),
            availableWidth: bounds.width
        )
        // `-[_DVTNSPathComponentCell _setResizedWidth:]` resets the drawn width too.
        currentWidths = resizedWidths
    }

    /// `-[_DVTNSPathCell _updateSizesForInteriorFrame:]`, NSPathCell's own fitting: when the path
    /// is too wide, the middle components — all but the first and the last two — level down from
    /// the widest, then the first component shrinks to its minimum, then the one before the last.
    /// The last component never shrinks.
    private static func resizedWidths(fullWidths: [CGFloat], minimumWidths: [CGFloat], availableWidth: CGFloat) -> [CGFloat] {
        var resizedWidths = fullWidths
        let count = fullWidths.count
        guard count > 1 else { return resizedWidths }
        var excess = fullWidths.reduce(0, +) - availableWidth
        guard excess > 0 else { return resizedWidths }

        if count >= 4 {
            // The widest middle component shrinks to the next widest one's width, then the two of
            // them to the third's, and so on; the last step takes them all to the widest one's
            // minimum width.
            let middleIndices = (1 ..< count - 2).sorted { fullWidths[$0] > fullWidths[$1] }
            let widestIndex = middleIndices[0]
            var levelledCount = 1
            while levelledCount <= middleIndices.count {
                let floorWidth = levelledCount == middleIndices.count
                    ? minimumWidths[widestIndex]
                    : resizedWidths[middleIndices[levelledCount]]
                let reduction = (resizedWidths[widestIndex] - floorWidth) * CGFloat(levelledCount)
                let takenWidth = min(reduction, excess)
                for position in 0 ..< levelledCount {
                    resizedWidths[middleIndices[position]] -= takenWidth / CGFloat(levelledCount)
                }
                let reductionCoversExcess = reduction > excess
                excess -= takenWidth
                levelledCount += 1
                if reductionCoversExcess {
                    break
                }
            }
        }

        if excess > 0.5 {
            let firstShrinkableWidth = resizedWidths[0] - minimumWidths[0]
            let firstTakenWidth = min(excess, firstShrinkableWidth)
            resizedWidths[0] -= firstTakenWidth
            if count >= 3, firstShrinkableWidth <= excess {
                let beforeLastIndex = count - 2
                resizedWidths[beforeLastIndex] -= min(excess - firstTakenWidth, resizedWidths[beforeLastIndex] - minimumWidths[beforeLastIndex])
            }
        }
        return resizedWidths
    }

    /// `-[_DVTNSPathCell rectOfPathComponentCell:withFrame:inView:]`: components follow each other
    /// from the leading edge; the one that crosses the trailing edge is clipped, and the ones
    /// after it are not shown at all.
    private func componentFrames() -> [NSRect] {
        fitComponentsIfNeeded()
        var frames: [NSRect] = []
        var originX = bounds.minX
        var hasCrossedTrailingEdge = false
        for width in currentWidths {
            guard !hasCrossedTrailingEdge else {
                frames.append(.zero)
                continue
            }
            frames.append(NSIntersectionRect(bounds, NSRect(x: originX, y: bounds.minY, width: width, height: bounds.height)))
            originX += width
            hasCrossedTrailingEdge = originX > bounds.maxX
        }
        return frames
    }

    private func frameOfComponent(at index: Int) -> NSRect {
        let frames = componentFrames()
        return frames.indices.contains(index) ? frames[index] : .zero
    }

    private func componentIndex(at point: NSPoint) -> Int? {
        componentFrames().firstIndex { NSMouseInRect(point, $0, isFlipped) }
    }

    private func pixelAlignedDown(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 1
        return (value * scale).rounded(.down) / scale
    }

    // MARK: - Hover

    public override func mouseEntered(with event: NSEvent) {
        updateHoveredComponent(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHoveredComponent(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        setHoveredComponentIndex(nil)
    }

    private func updateHoveredComponent(at point: NSPoint) {
        let index = componentIndex(at: point)
        setHoveredComponentIndex(index.flatMap { isInteractiveComponent(at: $0) ? $0 : nil })
    }

    /// `-[_DVTNSPathControl updateTrackingAreas]` does this whenever the path changes: the
    /// component now under the pointer is the hovered one.
    private func updateHoveredComponentFromPointer() {
        guard let window else {
            setHoveredComponentIndex(nil)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point) {
            updateHoveredComponent(at: point)
        } else {
            setHoveredComponentIndex(nil)
        }
    }

    private func setHoveredComponentIndex(_ index: Int?) {
        guard hoveredComponentIndex != index else { return }
        hoveredComponentIndex = index
        needsDisplay = true
        animateWidthsTowardHoverTargets()
    }

    /// `-[_DVTNSPathCell _createHoverChangeAnimation]`: the hovered component widens to its full
    /// width and the others go back to their resized widths. Nothing moves unless the path is
    /// squeezed.
    private func animateWidthsTowardHoverTargets() {
        fitComponentsIfNeeded()
        hoverAnimation?.stop()
        hoverAnimation = nil
        let targetWidths = components.indices.map { $0 == hoveredComponentIndex ? fullWidths[$0] : resizedWidths[$0] }
        guard targetWidths != currentWidths else { return }
        let originWidths = currentWidths
        let animation = HoverAnimation(duration: Metrics.hoverAnimationDuration, animationCurve: .easeInOut)
        animation.animationBlockingMode = .nonblocking
        animation.progressHandler = { [weak self] progress in
            guard let self, currentWidths.count == originWidths.count else { return }
            // `-[_DVTNSPathCell animation:didReachProgressMark:]` interpolates with the
            // animation's raw progress, so the widths move linearly whatever the curve.
            currentWidths = zip(originWidths, targetWidths).map { originWidth, targetWidth in
                originWidth + (targetWidth - originWidth) * CGFloat(progress)
            }
            needsDisplay = true
            noteFocusRingMaskChanged()
        }
        hoverAnimation = animation
        animation.start()
    }

    // MARK: - Menus

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled, let index = componentIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        // `-[DVTPathCell trackMouse:inRect:ofView:untilMouseUp:]`: the menu opens on the press.
        popUpMenuForComponent(at: index)
    }

    /// `-[DVTPathControl rightMouseDown:]`: a secondary click opens the component's menu too.
    public override func rightMouseDown(with event: NSEvent) {
        guard isEnabled,
              let index = componentIndex(at: convert(event.locationInWindow, from: nil)),
              popUpMenuForComponent(at: index)
        else {
            super.rightMouseDown(with: event)
            return
        }
    }

    /// `-[DVTPathCell popUpMenuForComponentCell:inRect:ofView:withMenuItems:]`
    @discardableResult
    private func popUpMenuForComponent(at index: Int) -> Bool {
        guard isInteractiveComponent(at: index) else { return false }
        let frame = frameOfComponent(at: index)
        guard !frame.isEmpty else { return false }
        let menu = makeMenu(forComponentAt: index)
        let positioningItem = components[index].value.flatMap { componentValue in
            menu.items.first { ($0.representedObject as? Selection)?.value == componentValue }
        }
        let location = NSPoint(
            x: frame.minX + (index == 0 ? Metrics.firstComponentMenuHorizontalOffset : Metrics.menuHorizontalOffset),
            y: frame.midY + Metrics.menuVerticalOffset
        )
        menuPresenter(menu, positioningItem, location, self)
        // The pointer may have left the component while the menu was up.
        updateHoveredComponentFromPointer()
        return true
    }

    /// `-[DVTPathCell _menuItemWithItem:additionalItems:currentGroupIdentifier:indentationLevel:]`:
    /// the items carry no state; the current one is the item laid over the component.
    private func makeMenu(forComponentAt index: Int) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.autoenablesItems = false
        menu.font = titleFont
        for menuItem in components[index].menuItems {
            if menuItem.isPrecededBySeparator, !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: menuItem.title, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = menuItem.isEnabled
            item.representedObject = Selection(componentIndex: index, value: menuItem.value)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? Selection else { return }
        lastSelection = selection
        sendAction(action, to: target)
    }

    // MARK: - Keyboard

    /// `-[DVTPathControl acceptsFirstResponder]`: the control takes focus only while the window
    /// moves the key view — Tab and Shift-Tab — never from a click.
    public override var acceptsFirstResponder: Bool {
        guard let window else { return false }
        if window.firstResponder === self { return true }
        return window.keyViewSelectionDirection != .directSelection && components.contains(where: \.isInteractive)
    }

    /// `-[DVTPathControl becomeFirstResponder]`: Tab focuses the first component, Shift-Tab the
    /// last.
    public override func becomeFirstResponder() -> Bool {
        let interactiveIndices = components.indices.filter(isInteractiveComponent(at:))
        guard let firstIndex = interactiveIndices.first, let lastIndex = interactiveIndices.last else { return false }
        switch window?.keyViewSelectionDirection {
        case .selectingNext:
            keyFocusedComponentIndex = firstIndex
        case .selectingPrevious:
            keyFocusedComponentIndex = lastIndex
        default:
            break
        }
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    /// `-[DVTPathControl focusRingMaskBounds]`: the ring goes around the focused component only.
    public override var focusRingMaskBounds: NSRect {
        guard let keyFocusedComponentIndex else { return .zero }
        return frameOfComponent(at: keyFocusedComponentIndex)
    }

    public override func drawFocusRingMask() {
        focusRingMaskBounds.fill()
    }

    /// `-[DVTPathControl keyDown:]`: Space and Return open the focused component's menu.
    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            popUpMenuForKeyFocusedComponent()
        default:
            interpretKeyEvents([event])
        }
    }

    public override func moveLeft(_ sender: Any?) {
        focusPreviousComponent()
    }

    public override func moveRight(_ sender: Any?) {
        focusNextComponent()
    }

    public override func moveUp(_ sender: Any?) {
        popUpMenuForKeyFocusedComponent()
    }

    public override func moveDown(_ sender: Any?) {
        popUpMenuForKeyFocusedComponent()
    }

    /// `-[DVTPathControl selectNextKeyView:]`: Tab walks the components before it leaves the
    /// control.
    public override func insertTab(_ sender: Any?) {
        if !focusNextComponent() {
            window?.selectKeyView(following: self)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        if !focusPreviousComponent() {
            window?.selectKeyView(preceding: self)
        }
    }

    private func popUpMenuForKeyFocusedComponent() {
        guard let keyFocusedComponentIndex else { return }
        popUpMenuForComponent(at: keyFocusedComponentIndex)
    }

    /// `-[DVTPathControl focusPreviousComponentCell]`, skipping components without a menu: with
    /// nothing focused yet there is nothing before it.
    @discardableResult
    private func focusPreviousComponent() -> Bool {
        guard let keyFocusedComponentIndex,
              let index = components.indices.last(where: { $0 < keyFocusedComponentIndex && isInteractiveComponent(at: $0) })
        else { return false }
        self.keyFocusedComponentIndex = index
        noteFocusRingMaskChanged()
        return true
    }

    /// `-[DVTPathControl focusNextComponentCell]`, skipping components without a menu: with
    /// nothing focused yet the first one with a menu is next.
    @discardableResult
    private func focusNextComponent() -> Bool {
        let focusedIndex = keyFocusedComponentIndex ?? -1
        guard let index = components.indices.first(where: { $0 > focusedIndex && isInteractiveComponent(at: $0) }) else { return false }
        keyFocusedComponentIndex = index
        noteFocusRingMaskChanged()
        return true
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let frames = componentFrames()
        let isWindowActive = isWindowActive
        let isDarkAppearance = isDarkAppearance
        for index in components.indices where !frames[index].isEmpty {
            drawComponent(at: index, in: frames[index], isWindowActive: isWindowActive, isDarkAppearance: isDarkAppearance)
        }
    }

    /// `-[NSWindow dvt_useActiveAppearance]` (DVTCocoaAdditionsKit), short of the private
    /// `hasKeyAppearance` it also consults.
    private var isWindowActive: Bool {
        guard let window else { return false }
        return window.isKeyWindow || window.isMainWindow || window.styleMask.contains(.fullScreen) || window is NSPanel
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// `-[DVTPathComponentCell drawWithFrame:inView:]`: the divider, then the highlight, then the
    /// title.
    private func drawComponent(at index: Int, in frame: NSRect, isWindowActive: Bool, isDarkAppearance: Bool) {
        let isHovered = index == hoveredComponentIndex
        // The last component's slot stays empty until it is hovered.
        if index != components.count - 1 || isHovered {
            drawDivider(ofComponentAt: index, in: frame, isActive: isEnabled && isWindowActive, isHovered: isHovered, isDarkAppearance: isDarkAppearance)
        }
        if isHovered {
            drawHighlight(in: frame, isDarkAppearance: isDarkAppearance)
        }
        drawTitle(ofComponentAt: index, in: frame, isWindowActive: isWindowActive, isDarkAppearance: isDarkAppearance)
    }

    /// `-[DVTPathComponentCell _drawDividerForFrame:inControlView:]`
    private func drawDivider(ofComponentAt index: Int, in frame: NSRect, isActive: Bool, isHovered: Bool, isDarkAppearance: Bool) {
        let image = isHovered ? Self.popUpIndicatorImage(isActive: isActive) : Self.separatorImage(isActive: isActive)
        guard let image else { return }
        let slot = NSRect(x: frame.maxX - Metrics.dividerWidth, y: frame.minY, width: Metrics.dividerWidth, height: frame.height)
        let imageFrame = NSRect(
            x: slot.midX - image.size.width / 2,
            y: slot.midY - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        guard imageFrame.minX > frame.minX + leadingMargin(ofComponentAt: index) + Metrics.iconWidth else { return }
        Self.draw(image, in: imageFrame, tintedWith: Self.dividerColor(isActive: isActive, isHovered: isHovered, isDarkAppearance: isDarkAppearance))
    }

    /// `-[DVTPathComponentCell _drawHoveredInFrame:]`, flat highlights and no insets: the whole
    /// component, divider slot included, no taller than `_highlightHeight` and centred when
    /// shorter than the control.
    private func drawHighlight(in frame: NSRect, isDarkAppearance: Bool) {
        let height = min(frame.height, highlightHeight)
        let originY = height == frame.height ? frame.minY : pixelAlignedDown(frame.midY - height / 2)
        Self.hoverFillColor(isDarkAppearance: isDarkAppearance).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: frame.minX, y: originY, width: frame.width, height: height),
            xRadius: Metrics.highlightCornerRadius,
            yRadius: Metrics.highlightCornerRadius
        ).fill()
    }

    /// `-[DVTPathComponentCell _highlightHeight]`
    private var highlightHeight: CGFloat {
        switch controlSize {
        case .small, .mini:
            21
        default:
            28
        }
    }

    /// `-[DVTPathComponentCell drawInteriorWithFrame:inView:]`
    private func drawTitle(ofComponentAt index: Int, in frame: NSRect, isWindowActive: Bool, isDarkAppearance: Bool) {
        let component = components[index]
        let leadingMargin = leadingMargin(ofComponentAt: index)
        guard !component.title.isEmpty, frame.width - (leadingMargin + Metrics.dividerWidth) > Metrics.minimumTitleRoom else { return }
        let title = NSAttributedString(string: component.title, attributes: [
            .font: titleFont,
            .foregroundColor: component.titleColor ?? Self.defaultTitleColor(isWindowActive: isWindowActive, isDarkAppearance: isDarkAppearance),
            .paragraphStyle: Self.clippingParagraphStyle,
        ])
        let titleSize = title.size()
        let origin = NSPoint(x: frame.minX + leadingMargin, y: pixelAlignedDown(frame.midY - titleSize.height / 2))
        let room = frame.width - (leadingMargin + Metrics.dividerWidth - Metrics.titleRoomIntoDivider)
        if titleSize.width - room <= Metrics.titleOverflowTolerance {
            title.draw(at: origin)
        } else {
            drawFadingTitle(title, in: NSRect(x: origin.x, y: origin.y, width: room, height: titleSize.height))
        }
    }

    /// `-[DVTPathComponentCell _drawGradientMaskForTitleRect:]`: a title too long for its room
    /// fades out over the last 10 points instead of ending in an ellipsis.
    private func drawFadingTitle(_ title: NSAttributedString, in titleFrame: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        NSGraphicsContext.saveGraphicsState()
        context.cgContext.clip(to: titleFrame)
        context.cgContext.beginTransparencyLayer(in: titleFrame, auxiliaryInfo: nil)
        NSGraphicsContext.saveGraphicsState()
        title.draw(at: titleFrame.origin)
        let fadeFrame = titleFrame.width - Metrics.titleFadeWidth > 0
            ? NSRect(x: titleFrame.maxX - Metrics.titleFadeWidth, y: titleFrame.minY, width: Metrics.titleFadeWidth, height: titleFrame.height)
            : titleFrame
        context.compositingOperation = .destinationIn
        NSGradient(starting: .black, ending: .clear)?.draw(
            in: NSRect(x: fadeFrame.minX, y: fadeFrame.minY, width: fadeFrame.width + 1, height: fadeFrame.height),
            angle: 0
        )
        NSGraphicsContext.restoreGraphicsState()
        context.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let clippingParagraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        return paragraphStyle
    }()

    /// `-[DVTPathComponentCell textColor]` with `drawsActive` set, as it is everywhere outside an
    /// inactive editor.
    private static func defaultTitleColor(isWindowActive: Bool, isDarkAppearance: Bool) -> NSColor {
        if isWindowActive {
            return .labelColor
        }
        return isDarkAppearance ? .secondaryLabelColor : .tertiaryLabelColor
    }

    /// `-[DVTPathComponentCell _drawDividerForFrame:inControlView:]` with `drawsActive` set.
    /// `isActive` is the control being enabled in an active window.
    private static func dividerColor(isActive: Bool, isHovered: Bool, isDarkAppearance: Bool) -> NSColor {
        if isDarkAppearance {
            return isActive ? .labelColor : .secondaryLabelColor
        }
        guard isActive else { return .tertiaryLabelColor }
        return isHovered ? .labelColor : .secondaryLabelColor
    }

    /// `-[DVTTheme hoveredScopeControlColor]` (DVTUserInterfaceKit)
    private static func hoverFillColor(isDarkAppearance: Bool) -> NSColor {
        (isDarkAppearance ? NSColor.white : NSColor.black).withAlphaComponent(0.05)
    }

    /// `+[DVTPathComponentCell initialize]`: `chevron.compact.right` at the small system font size,
    /// medium in an active window and bold in an inactive one, where it is drawn lighter.
    private static let activeSeparatorImage = symbolImage("chevron.compact.right", pointSize: NSFont.smallSystemFontSize, weight: .medium)
    private static let inactiveSeparatorImage = symbolImage("chevron.compact.right", pointSize: NSFont.smallSystemFontSize, weight: .bold)

    /// `-[DVTPathComponentCell _currentDividerImageForControlView:]` draws DVTKit's own
    /// `chevrons.popup` symbol here, at 8 points
    /// (`-[DVTPathComponentCell _hoverChevronSymbolConfigWithActiveAndEnabled:demiSized:]`). It
    /// is private to DVTKit, so this is SF Symbols' `chevron.up.chevron.down` at the same size.
    private static let activePopUpIndicatorImage = symbolImage("chevron.up.chevron.down", pointSize: 8, weight: .medium)
    private static let inactivePopUpIndicatorImage = symbolImage("chevron.up.chevron.down", pointSize: 8, weight: .bold)

    private static func separatorImage(isActive: Bool) -> NSImage? {
        isActive ? activeSeparatorImage : inactiveSeparatorImage
    }

    private static func popUpIndicatorImage(isActive: Bool) -> NSImage? {
        isActive ? activePopUpIndicatorImage : inactivePopUpIndicatorImage
    }

    private static func symbolImage(_ symbolName: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    /// `DVTCGContextDrawInRectWithOptionalTemplateTintColor`: a template image filled with one
    /// colour.
    private static func draw(_ image: NSImage, in frame: NSRect, tintedWith color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        frame.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // MARK: - Accessibility

    /// `-[_DVTNSPathCell accessibilityRoleAttribute]`
    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .list }

    public override func accessibilityOrientation() -> NSAccessibilityOrientation { .horizontal }

    /// `-[DVTPathCell accessibilityAttributeValue:]`: one element per component.
    public override func accessibilityChildren() -> [Any]? {
        if let componentAccessibilityElements {
            return componentAccessibilityElements
        }
        let elements = components.indices.map { ComponentAccessibilityElement(pathControl: self, componentIndex: $0) }
        componentAccessibilityElements = elements
        return elements
    }

    /// `DVTPathComponentCellAccessibilityObject`: a pop-up button whose value is the title, and
    /// whose press opens the component's menu.
    private final class ComponentAccessibilityElement: NSAccessibilityElement {
        private weak var pathControl: PopUpPathControl?

        private let componentIndex: Int

        init(pathControl: PopUpPathControl, componentIndex: Int) {
            self.pathControl = pathControl
            self.componentIndex = componentIndex
            super.init()
            let isInteractive = pathControl.isInteractiveComponent(at: componentIndex)
            setAccessibilityParent(pathControl)
            setAccessibilityRole(isInteractive ? .popUpButton : .staticText)
            setAccessibilityValue(pathControl.components[componentIndex].title)
            setAccessibilityEnabled(isInteractive)
        }

        override func accessibilityFrameInParentSpace() -> NSRect {
            pathControl?.frameOfComponent(at: componentIndex) ?? .zero
        }

        override func accessibilityPerformPress() -> Bool {
            pathControl?.popUpMenuForComponent(at: componentIndex) ?? false
        }

        override func accessibilityPerformShowMenu() -> Bool {
            pathControl?.popUpMenuForComponent(at: componentIndex) ?? false
        }
    }

    // MARK: - Animation

    /// `_DVTNSPathLocationAnimation`: reports every progress step.
    private final class HoverAnimation: NSAnimation {
        var progressHandler: ((NSAnimation.Progress) -> Void)?

        override var currentProgress: NSAnimation.Progress {
            didSet {
                progressHandler?(currentProgress)
            }
        }
    }
}

#endif
