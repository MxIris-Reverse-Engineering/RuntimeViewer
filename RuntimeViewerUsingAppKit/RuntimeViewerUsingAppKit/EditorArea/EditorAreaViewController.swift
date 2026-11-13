import AppKit
import RxAppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

/// The editor area: its panes in nested split views, arranged as `EditorLayout` says — a root split
/// view, and a split view across it for every child split.
///
/// The coordinator makes the panes and hands them over with each layout (`apply(layout:panes:)`),
/// so the views never wait for a pane the layout already names. Sizes follow Xcode: a change to the
/// root's own items equalizes every split, a change inside a child split equalizes that split alone,
/// and turning the orientation keeps them (`EditorLayout.splitsToEqualize(comparedWith:)`).
///
/// The keyboard focus decides the focused pane: whichever pane the window's first responder enters
/// becomes the focused one, the way an Xcode editor pane becomes the last active one. The other way
/// round, a pane that takes the focus through a command or a route gets the keyboard focus too
/// (`focus(_:movingKeyboardFocus:)`).
final class EditorAreaViewController: BaseViewController<EditorAreaViewModel> {
    /// The narrowest a pane gets while a divider is dragged — Xcode's `IDEEditorSplitMinimumSize` —
    /// along the split's axis; the divider stops there and pushes nothing, as in Xcode.
    static let minimumPaneExtent: CGFloat = 200

    private let rootSplitView = EditorSplitView()

    /// The split view of each child split, by its index in the applied layout's `items`.
    private var childSplitViews: [Int: EditorSplitView] = [:]

    private var appliedLayout: EditorLayout?

    private var paneViewControllers: [EditorPane.ID: EditorPaneViewController] = [:]

    /// Split views to equalize once they have a size: a split view laid out before its window gave
    /// it any extent has nothing to divide yet.
    private var splitViewsAwaitingEqualization: [EditorSplitView] = []

    private let paneReceivedKeyboardFocusRelay = PublishRelay<EditorPane.ID>()

    private var firstResponderObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()

        rootSplitView.delegate = self

        containerView.hierarchy {
            rootSplitView
        }

        rootSplitView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard firstResponderObservation == nil, let window = view.window else { return }
        firstResponderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, let paneID = self.paneID(containing: window.firstResponder) else { return }
                self.paneReceivedKeyboardFocusRelay.accept(paneID)
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        guard !splitViewsAwaitingEqualization.isEmpty else { return }
        let splitViews = splitViewsAwaitingEqualization
        splitViewsAwaitingEqualization = []
        for splitView in splitViews {
            equalize(splitView)
        }
    }

    override func setupBindings(for viewModel: EditorAreaViewModel) {
        super.setupBindings(for: viewModel)

        let input = EditorAreaViewModel.Input(
            paneReceivedKeyboardFocus: paneReceivedKeyboardFocusRelay.asSignal()
        )
        _ = viewModel.transform(input)
    }

    // MARK: - Panes

    /// Shows `panes` arranged as `layout` says. A pane's view controller stays the same for as long
    /// as the pane exists, wherever the layout moves it.
    func apply(layout: EditorLayout, panes: [EditorPane.ID: EditorPaneViewController]) {
        loadViewIfNeeded()

        for (paneID, paneViewController) in paneViewControllers where panes[paneID] !== paneViewController {
            paneViewController.view.removeFromSuperview()
            paneViewController.removeFromParent()
        }
        for paneViewController in panes.values where paneViewController.parent !== self {
            addChild(paneViewController)
        }
        paneViewControllers = panes

        let equalizedSplits = appliedLayout.map { layout.splitsToEqualize(comparedWith: $0) } ?? .all
        switch equalizedSplits {
        case .all:
            rebuildSplitViews(for: layout)
        case .children(let itemIndices):
            for itemIndex in itemIndices {
                rebuildChildSplitView(at: itemIndex, for: layout)
            }
        case .none:
            break
        }
        // Before equalizing: a split view divides its width or its height by its orientation.
        updateOrientations(for: layout)
        switch equalizedSplits {
        case .all:
            resetSizes()
        case .children(let itemIndices):
            for itemIndex in itemIndices {
                if let childSplitView = childSplitViews[itemIndex] {
                    equalize(childSplitView)
                }
            }
        case .none:
            break
        }
        appliedLayout = layout
    }

    /// Gives `paneID` the keyboard focus, as Xcode's `takeFocus` does, unless it already holds it.
    /// With `movingKeyboardFocus` off, only while the keyboard focus is in the editor area already:
    /// a route that comes from the sidebar or the Inspector moves the focused pane, not the keyboard.
    func focus(_ paneID: EditorPane.ID, movingKeyboardFocus: Bool) {
        guard let window = view.window, let paneViewController = paneViewControllers[paneID] else { return }
        let firstResponder = window.firstResponder
        if let firstResponderView = firstResponder as? NSView, firstResponderView.isDescendant(of: paneViewController.view) {
            return
        }
        let keyboardFocusIsInEditorArea = (firstResponder as? NSView)?.isDescendant(of: view) ?? (firstResponder === window)
        guard movingKeyboardFocus || keyboardFocusIsInEditorArea else { return }
        guard let focusableView = paneViewController.focusableContentView else { return }
        window.makeFirstResponder(focusableView)
    }

    /// Reset Editor Sizes: every split shares its extent equally among its panes.
    func resetSizes() {
        equalize(rootSplitView)
        for childSplitView in childSplitViews.values {
            equalize(childSplitView)
        }
    }

    private func paneID(containing responder: NSResponder?) -> EditorPane.ID? {
        guard let responderView = responder as? NSView else { return nil }
        return paneViewControllers.first { responderView.isDescendant(of: $0.value.view) }?.key
    }

    // MARK: - Split views

    private func rebuildSplitViews(for layout: EditorLayout) {
        removeArrangedSubviews(of: rootSplitView)
        childSplitViews = [:]
        for (itemIndex, item) in layout.items.enumerated() {
            switch item {
            case .pane(let paneID):
                if let paneView = paneViewControllers[paneID]?.view {
                    addArrangedSubview(paneView, to: rootSplitView)
                }
            case .split(let paneIDs):
                let childSplitView = makeChildSplitView(holding: paneIDs)
                childSplitViews[itemIndex] = childSplitView
                addArrangedSubview(childSplitView, to: rootSplitView)
            }
        }
    }

    private func rebuildChildSplitView(at itemIndex: Int, for layout: EditorLayout) {
        guard case .split(let paneIDs) = layout.items[itemIndex], let childSplitView = childSplitViews[itemIndex] else {
            // Only the root's own items changing can make or unmake a child split, and that
            // rebuilds everything.
            rebuildSplitViews(for: layout)
            return
        }
        removeArrangedSubviews(of: childSplitView)
        for paneID in paneIDs {
            if let paneView = paneViewControllers[paneID]?.view {
                addArrangedSubview(paneView, to: childSplitView)
            }
        }
    }

    /// A new child split view starts at the root's size, so that the panes put in it have one to start
    /// from as well (`addArrangedSubview(_:to:)`).
    private func makeChildSplitView(holding paneIDs: [EditorPane.ID]) -> EditorSplitView {
        let childSplitView = EditorSplitView(frame: rootSplitView.bounds)
        childSplitView.delegate = self
        for paneID in paneIDs {
            if let paneView = paneViewControllers[paneID]?.view {
                addArrangedSubview(paneView, to: childSplitView)
            }
        }
        return childSplitView
    }

    /// Adds `arrangedView` to `splitView`, sized to the split view when it has no size yet. A pane or
    /// child split view made since the last layout has none, and the layout `equalize(_:)` forces
    /// before the split view has framed it solves everything inside it against a zero width: the
    /// pane's tab bar and the editor cannot fit, and AppKit breaks constraints to say so. The split
    /// view shrinks the oversized view to its share on its next layout.
    private func addArrangedSubview(_ arrangedView: NSView, to splitView: NSSplitView) {
        if arrangedView.frame.isEmpty {
            arrangedView.frame = splitView.bounds
        }
        splitView.addArrangedSubview(arrangedView)
    }

    private func removeArrangedSubviews(of splitView: NSSplitView) {
        for arrangedSubview in splitView.arrangedSubviews {
            splitView.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }
    }

    /// Sets each split view's direction, touching only the ones that turn: setting `isVertical`
    /// lays a split view out again.
    private func updateOrientations(for layout: EditorLayout) {
        let rootIsVertical = layout.orientation == .sideBySide
        if rootSplitView.isVertical != rootIsVertical {
            rootSplitView.isVertical = rootIsVertical
        }
        for childSplitView in childSplitViews.values where childSplitView.isVertical == rootIsVertical {
            childSplitView.isVertical = !rootIsVertical
        }
    }

    /// Shares `splitView`'s extent equally among its panes: `floor((extent − dividers) / count)`
    /// each, as `-[IDESafeAreaAwareSplitView equalizePaneSizes]` does.
    private func equalize(_ splitView: EditorSplitView) {
        let paneCount = splitView.arrangedSubviews.count
        guard paneCount > 1 else { return }
        // Not before the window has sized the editor area: a forced layout would solve every pane
        // against a zero width.
        guard view.window != nil, !view.bounds.isEmpty else {
            awaitEqualization(of: splitView)
            return
        }
        view.layoutSubtreeIfNeeded()
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let dividerExtent = CGFloat(paneCount - 1) * splitView.dividerThickness
        guard extent > dividerExtent else {
            awaitEqualization(of: splitView)
            return
        }
        let paneExtent = floor((extent - dividerExtent) / CGFloat(paneCount))
        for dividerIndex in 0 ..< paneCount - 1 {
            let position = CGFloat(dividerIndex + 1) * paneExtent + CGFloat(dividerIndex) * splitView.dividerThickness
            splitView.setPosition(position, ofDividerAt: dividerIndex)
        }
    }

    private func awaitEqualization(of splitView: EditorSplitView) {
        guard !splitViewsAwaitingEqualization.contains(where: { $0 === splitView }) else { return }
        splitViewsAwaitingEqualization.append(splitView)
    }
}

// MARK: - NSSplitViewDelegate

extension EditorAreaViewController: NSSplitViewDelegate {
    /// Xcode counts a divider's thickness into the minimum of the pane before it, so that pane keeps
    /// 203 points and the one after the divider 200 (IDEKit 27.2 0x13E454; RE notes "Editor panes —
    /// visuals" §5).
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + Self.minimumPaneExtent + splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - Self.minimumPaneExtent
    }
}

// MARK: - Split View

/// A split view of the editor area, Xcode's `IDEEditorSplitView`: the thin divider style, 3 points
/// thick (`-[IDEEditorMultipleSplit loadView]`, IDEKit 27.2 0x13C3A0).
///
/// Xcode draws the divider in an opaque colour its editor theme computes for the appearance and for
/// whether the pane is active; the separator colour stands in for it.
final class EditorSplitView: NSSplitView {
    override var dividerThickness: CGFloat {
        3
    }

    override var dividerColor: NSColor {
        .separatorColor
    }

    /// The top safe area the dividers were last drawn for. It moves with the toolbar — hidden, or
    /// gone in full screen — without the split view resizing, so nothing else redraws them.
    private var dividerTopSafeAreaInset: CGFloat = 0

    override func layout() {
        super.layout()
        if safeAreaInsets.top != dividerTopSafeAreaInset {
            dividerTopSafeAreaInset = safeAreaInsets.top
            needsDisplay = true
        }
    }

    /// Draws a divider only below the split view's top safe area. The editor area runs under the
    /// toolbar, whose strip shows the panes' content blurred in their scroll pockets
    /// (`EditorPaneViewController`), and a divider drawn up through it split the toolbar.
    override func drawDivider(in rect: NSRect) {
        let topSafeAreaInset = min(safeAreaInsets.top, bounds.height)
        var drawableRect = bounds
        drawableRect.size.height -= topSafeAreaInset
        if isFlipped {
            drawableRect.origin.y += topSafeAreaInset
        }
        let dividerRect = rect.intersection(drawableRect)
        guard !dividerRect.isEmpty else { return }
        super.drawDivider(in: dividerRect)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
        arrangesAllSubviews = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
