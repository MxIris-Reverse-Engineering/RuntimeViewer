import AppKit
import Testing
import RuntimeViewerUI

/// Throwaway probe, never committed: which of the private scroll pocket calls that
/// `NavigatorScrollViewLayout` makes lets the top pocket's edge line run across a legacy (always shown)
/// scroller under a floating group row.
///
/// Each configuration builds the sidebar's list the way the sidebar builds it — a source list outline
/// with floating group rows in UIFoundation's `ScrollView`, a 28-point bar over the top edge whose height
/// reaches the page as safe area (the tab switcher's), a 44-point bar over the bottom edge (the filter
/// bar) — scrolls until a group row floats, and prints the geometry and the top pocket's layer tree.
/// Nothing is asserted; the output is read by hand.
@Suite("Scroll pocket separator probe", .serialized)
@MainActor
struct ScrollPocketSeparatorProbeTests {
    enum Configuration: String, CaseIterable, Sendable {
        /// Proposal 0052's first phase: safe area and clip view insets only, no private call.
        case publicOnly
        /// The first phase, plus both edges always showing their pocket.
        case alwaysShownEdges
        /// The first phase, plus the two bars registered as pocket containers, as plain views.
        case plainViewContainers
        /// The first phase, plus the two bars registered as pocket containers, answering the bar style.
        case barStyleContainers
        /// `NavigatorScrollViewLayout` exactly as the sidebar uses it.
        case navigatorScrollViewLayout
    }

    @available(macOS 26.0, *)
    @Test(arguments: Configuration.allCases)
    func reportTopPocket(configuration: Configuration) {
        let fixture = Fixture(configuration: configuration)
        defer { fixture.tearDown() }
        fixture.scrollUntilGroupRowFloats()
        print(fixture.report())
    }
}

// MARK: - Fixture

extension ScrollPocketSeparatorProbeTests {
    @available(macOS 26.0, *)
    @MainActor
    final class Fixture {
        static let topBarHeight: CGFloat = 28
        static let bottomBarHeight: CGFloat = 44

        let configuration: Configuration
        let window: NSWindow
        let containerView = NSView()
        let scrollView: ScrollView
        let outlineView: StatefulOutlineView
        let topBarView: NSView
        let bottomBarView: NSView
        private let dataSource = ProbeDataSource()
        private var navigatorScrollViewLayout: NavigatorScrollViewLayout?

        var clipView: NSClipView { scrollView.contentView }

        init(configuration: Configuration) {
            self.configuration = configuration
            window = NSWindow(
                contentRect: NSRect(x: -6000, y: -6000, width: 372, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = containerView
            // The tab switcher's bar reaches a page as safe area from outside.
            containerView.additionalSafeAreaInsets = NSEdgeInsets(top: Self.topBarHeight, left: 0, bottom: 0, right: 0)

            let usesBarStyle = configuration == .barStyleContainers || configuration == .navigatorScrollViewLayout
            topBarView = usesBarStyle ? ScrollPocketBarView() : NSView()
            bottomBarView = usesBarStyle ? ScrollPocketBarView() : NSView()

            // The sidebar's own factory call.
            let scrollableOutlineView: (ScrollView, StatefulOutlineView) = StatefulOutlineView.scrollableSingleColumnOutlineView()
            scrollView = scrollableOutlineView.0
            outlineView = scrollableOutlineView.1
            // As the sidebar's `ImageLoadedView` sets it up.
            scrollView.autohidesScrollers = true
            scrollView.hidesVisualEffectView = true
            // What "Show scroll bars: Always" gives: the scroller beside the clip view, not over it.
            scrollView.scrollerStyle = .legacy
            outlineView.style = .sourceList
            outlineView.floatsGroupRows = true
            outlineView.dataSource = dataSource
            outlineView.delegate = dataSource

            containerView.addSubview(scrollView)
            containerView.addSubview(topBarView)
            containerView.addSubview(bottomBarView)
            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            topBarView.snp.makeConstraints { make in
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(Self.topBarHeight)
            }
            bottomBarView.snp.makeConstraints { make in
                make.leading.trailing.bottom.equalToSuperview()
                make.height.equalTo(Self.bottomBarHeight)
            }

            switch configuration {
            case .publicOnly:
                applyPublicLayout()
            case .alwaysShownEdges:
                applyPublicLayout()
                scrollView.box.alwaysShownScrollPocketEdges = [.top, .bottom]
            case .plainViewContainers, .barStyleContainers:
                applyPublicLayout()
                scrollView.box.registerScrollPocketContainer(topBarView, on: .top)
                scrollView.box.registerScrollPocketContainer(bottomBarView, on: .bottom)
            case .navigatorScrollViewLayout:
                let layout = NavigatorScrollViewLayout(scrollView: scrollView, bottomOverlayViews: [bottomBarView])
                layout.inheritedTopOverlayViews = [topBarView]
                navigatorScrollViewLayout = layout
            }

            outlineView.reloadData()
            for section in dataSource.sections {
                outlineView.expandItem(section)
            }

            window.orderFrontRegardless()
            layoutAndDisplay()
            if configuration != .navigatorScrollViewLayout {
                applyPublicContentInsets()
                layoutAndDisplay()
            }
        }

        /// The first phase's part that needs no private call: the bottom bar becomes safe area, and the clip
        /// view stops adjusting its insets.
        private func applyPublicLayout() {
            clipView.automaticallyAdjustsContentInsets = false
            scrollView.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.bottomBarHeight, right: 0)
        }

        private func applyPublicContentInsets() {
            let safeAreaInsets = scrollView.safeAreaInsets
            clipView.contentInsets = NSEdgeInsets(
                top: safeAreaInsets.top + NavigatorScrollViewLayout.topContentInsetBeyondSafeArea,
                left: 0,
                bottom: safeAreaInsets.bottom,
                right: 0
            )
        }

        /// Scrolls well into the first section, so that its header floats under the top bar.
        func scrollUntilGroupRowFloats() {
            clipView.scroll(to: NSPoint(x: 0, y: 400 - clipView.contentInsets.top))
            scrollView.reflectScrolledClipView(clipView)
            layoutAndDisplay()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            layoutAndDisplay()
        }

        func layoutAndDisplay() {
            containerView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
        }

        // MARK: Report

        func report() -> String {
            var lines: [String] = []
            lines.append("===== \(configuration.rawValue)")
            lines.append("outline effectiveStyle=\(outlineView.effectiveStyle.rawValue) scrollerStyle=\(scrollView.scrollerStyle.rawValue)")
            lines.append("scrollView bounds=\(format(scrollView.bounds)) safeAreaInsets=\(format(scrollView.safeAreaInsets))")
            lines.append("clipView frame=\(format(clipView.frame)) contentInsets=\(format(clipView.contentInsets))")
            if let verticalScroller = scrollView.verticalScroller {
                lines.append("verticalScroller frame=\(format(verticalScroller.frame)) hidden=\(verticalScroller.isHidden)")
            }
            lines.append("-- scroll view subviews")
            for subview in scrollView.subviews {
                lines.append("  \(type(of: subview)) frame=\(format(subview.frame)) hidden=\(subview.isHidden)")
                if String(describing: type(of: subview)).contains("Floating") {
                    for floatingSubview in subview.subviews {
                        lines.append("    \(type(of: floatingSubview)) frame=\(format(floatingSubview.frame)) hidden=\(floatingSubview.isHidden)")
                    }
                }
            }
            if let topPocket = scrollView.box.scrollPocket(on: .top) {
                lines.append("-- top pocket frame=\(format(topPocket.frame)) hidden=\(topPocket.isHidden) alpha=\(topPocket.alphaValue)")
                lines.append("-- top pocket views")
                appendViewTree(of: topPocket, depth: 1, into: &lines)
                if let pocketLayer = topPocket.layer {
                    lines.append("-- top pocket layers (frames in scroll view coordinates)")
                    appendLayerTree(of: pocketLayer, depth: 1, into: &lines)
                }
            } else {
                lines.append("-- no top pocket")
            }
            if let scrollViewLayer = scrollView.layer {
                lines.append("-- thin visible layers anywhere under the scroll view")
                appendThinLayers(under: scrollViewLayer, path: "scrollView", into: &lines)
            }
            return lines.joined(separator: "\n")
        }

        private func appendViewTree(of view: NSView, depth: Int, into lines: inout [String]) {
            guard depth <= 6 else { return }
            for subview in view.subviews {
                let frameInScrollView = scrollView.convert(subview.bounds, from: subview)
                lines.append(String(repeating: "  ", count: depth) + "\(type(of: subview)) frame=\(format(frameInScrollView)) hidden=\(subview.isHidden) alpha=\(subview.alphaValue)")
                appendViewTree(of: subview, depth: depth + 1, into: &lines)
            }
        }

        private func appendLayerTree(of layer: CALayer, depth: Int, into lines: inout [String]) {
            guard depth <= 10 else { return }
            lines.append(String(repeating: "  ", count: depth) + describe(layer))
            for sublayer in layer.sublayers ?? [] {
                appendLayerTree(of: sublayer, depth: depth + 1, into: &lines)
            }
        }

        private func appendThinLayers(under layer: CALayer, path: String, into lines: inout [String]) {
            for (index, sublayer) in (layer.sublayers ?? []).enumerated() {
                let sublayerPath = "\(path)/\(index):\(type(of: sublayer))"
                let frame = frameInScrollView(of: sublayer)
                let isThin = (frame.height > 0 && frame.height <= 1.5 && frame.width > 10)
                    || (frame.width > 0 && frame.width <= 1.5 && frame.height > 10)
                if isThin && !sublayer.isHidden && sublayer.opacity > 0 {
                    lines.append("  \(sublayerPath) \(describe(sublayer))")
                }
                appendThinLayers(under: sublayer, path: sublayerPath, into: &lines)
            }
        }

        private func frameInScrollView(of layer: CALayer) -> CGRect {
            guard let scrollViewLayer = scrollView.layer else { return layer.frame }
            return layer.convert(layer.bounds, to: scrollViewLayer)
        }

        private func describe(_ layer: CALayer) -> String {
            var description = "\(type(of: layer)) name=\(layer.name ?? "-") frame=\(format(frameInScrollView(of: layer)))"
            description += " hidden=\(layer.isHidden) opacity=\(layer.opacity)"
            if let backgroundColor = layer.backgroundColor {
                description += " background=\(format(backgroundColor))"
            }
            if layer.contents != nil {
                description += " contents"
            }
            if let compositingFilter = layer.compositingFilter {
                description += " compositingFilter=\(compositingFilter)"
            }
            if layer.mask != nil {
                description += " mask"
            }
            if let shapeLayer = layer as? CAShapeLayer {
                description += " path=\(shapeLayer.path.map { format($0.boundingBox) } ?? "-") lineWidth=\(shapeLayer.lineWidth)"
                if let strokeColor = shapeLayer.strokeColor {
                    description += " stroke=\(format(strokeColor))"
                }
                if let fillColor = shapeLayer.fillColor {
                    description += " fill=\(format(fillColor))"
                }
            }
            return description
        }

        private func format(_ rect: CGRect) -> String {
            String(format: "(%.1f, %.1f, %.1f, %.1f)", rect.minX, rect.minY, rect.width, rect.height)
        }

        private func format(_ insets: NSEdgeInsets) -> String {
            String(format: "(top %.1f, left %.1f, bottom %.1f, right %.1f)", insets.top, insets.left, insets.bottom, insets.right)
        }

        private func format(_ color: CGColor) -> String {
            let components = (color.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: " ")
            let colorSpaceName = color.colorSpace?.name.map { $0 as String } ?? "?"
            return "[\(colorSpaceName) \(components)]"
        }
    }

    // MARK: Data source

    final class ProbeNode {
        let title: String
        let children: [ProbeNode]

        init(title: String, children: [ProbeNode] = []) {
            self.title = title
            self.children = children
        }
    }

    final class ProbeDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let sections: [ProbeNode] = (0 ..< 3).map { sectionIndex in
            ProbeNode(
                title: "Section \(sectionIndex)",
                children: (0 ..< 60).map { childIndex in ProbeNode(title: "Row \(sectionIndex).\(childIndex)") }
            )
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? ProbeNode else { return sections.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? ProbeNode else { return sections[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? ProbeNode else { return false }
            return !node.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let node = item as? ProbeNode else { return false }
            return sections.contains { $0 === node }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? ProbeNode else { return nil }
            return NSTextField(labelWithString: node.title)
        }
    }
}
