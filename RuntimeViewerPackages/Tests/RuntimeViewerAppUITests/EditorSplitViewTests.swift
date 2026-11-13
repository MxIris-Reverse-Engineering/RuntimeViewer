import AppKit
import Metal
import QuartzCore
import Testing
import RuntimeViewerUI

/// Contract suite for `EditorSplitView`, the split view between the editor area's panes.
///
/// With a delegate that constrains its dividers, as the editor area's does, `NSSplitView` does not draw itself again
/// when an arranged view leaves it: the divider of a closed pane stayed in the split view's layer (measured on macOS
/// 27.2). The pane left beside it hides it only where its content is opaque, so the line showed through an empty
/// pane, the full height below the toolbar, and through the jump bar's scroll edge effect, which replays what lies
/// behind the pane — until something else, such as a resize of the window, redrew the split view.
///
/// The fixture is the split view under a toolbar, in the container the editor area puts it in, with the editor area's
/// delegate and transparent panes, so that what the split view's own layer holds is all that renders.
@Suite("EditorSplitView", .serialized)
@MainActor
struct EditorSplitViewTests {
    @Test("two panes are divided by a drawn divider", arguments: [true, false])
    func twoPanesAreDividedByADrawnDivider(isVertical: Bool) throws {
        let fixture = Fixture(isVertical: isVertical, paneCount: 2)
        defer { fixture.tearDown() }

        #expect(try fixture.renderedMaximumAlpha() > 0)
    }

    @Test("closing one of two panes leaves no divider behind", arguments: [true, false], [0, 1])
    func closingAPaneLeavesNoDividerBehind(isVertical: Bool, closedPaneIndex: Int) throws {
        let fixture = Fixture(isVertical: isVertical, paneCount: 2)
        defer { fixture.tearDown() }

        fixture.closePane(at: closedPaneIndex)

        #expect(try fixture.renderedMaximumAlpha() == 0)
    }

    @Test("closing the middle one of three panes leaves only the remaining divider", arguments: [true, false])
    func closingTheMiddlePaneLeavesOnlyTheRemainingDivider(isVertical: Bool) throws {
        let fixture = Fixture(isVertical: isVertical, paneCount: 3)
        defer { fixture.tearDown() }
        let closedDividerFrame = try #require(fixture.dividerFrame(at: 1))

        fixture.closePane(at: 1)

        let remainingDividerFrame = try #require(fixture.dividerFrame(at: 0))
        #expect(!remainingDividerFrame.intersects(closedDividerFrame))
        #expect(try fixture.renderedMaximumAlpha(in: closedDividerFrame) == 0)
        #expect(try fixture.renderedMaximumAlpha(in: remainingDividerFrame) > 0)
    }
}

// MARK: - Fixture

extension EditorSplitViewTests {
    @MainActor
    final class Fixture {
        let window: NSWindow
        let splitView: EditorSplitView
        private let delegate = MinimumPaneExtentDelegate()

        init(isVertical: Bool, paneCount: Int) {
            let bounds = NSRect(x: 0, y: 0, width: 900, height: 600)
            window = NSWindow(
                contentRect: bounds.offsetBy(dx: -6000, dy: -6000),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.toolbar = NSToolbar(identifier: "EditorSplitViewTests")
            window.toolbarStyle = .unified

            splitView = EditorSplitView(frame: bounds)
            splitView.isVertical = isVertical
            splitView.delegate = delegate
            for _ in 0 ..< paneCount {
                splitView.addArrangedSubview(NSView(frame: bounds))
            }
            window.contentView = ToolbarScrollPocketContainerView(contentView: splitView)

            window.orderFrontRegardless()
            layoutAndDisplay()
            let extent = isVertical ? splitView.bounds.width : splitView.bounds.height
            let paneExtent = floor((extent - CGFloat(paneCount - 1) * splitView.dividerThickness) / CGFloat(paneCount))
            for dividerIndex in 0 ..< paneCount - 1 {
                let position = CGFloat(dividerIndex + 1) * paneExtent + CGFloat(dividerIndex) * splitView.dividerThickness
                splitView.setPosition(position, ofDividerAt: dividerIndex)
            }
            layoutAndDisplay()
        }

        /// What the editor area does to close a pane (`EditorAreaViewController.apply(layout:panes:)`): the closed
        /// pane is taken out of the window, then every pane leaves the split view and the ones that remain come back
        /// in order.
        func closePane(at index: Int) {
            var remainingPanes = splitView.arrangedSubviews
            let closedPane = remainingPanes.remove(at: index)
            closedPane.removeFromSuperview()
            for arrangedSubview in splitView.arrangedSubviews {
                splitView.removeArrangedSubview(arrangedSubview)
                arrangedSubview.removeFromSuperview()
            }
            for pane in remainingPanes {
                splitView.addArrangedSubview(pane)
            }
            layoutAndDisplay()
        }

        /// The divider after the pane at `index`, in the split view's coordinates: the gap between that pane and the
        /// next.
        func dividerFrame(at index: Int) -> NSRect? {
            let panes = splitView.arrangedSubviews
            guard index + 1 < panes.count else { return nil }
            let leadingFrame = panes[index].frame
            let trailingFrame = panes[index + 1].frame
            if splitView.isVertical {
                return NSRect(x: leadingFrame.maxX, y: 0, width: trailingFrame.minX - leadingFrame.maxX, height: splitView.bounds.height)
            } else {
                return NSRect(x: 0, y: leadingFrame.maxY, width: splitView.bounds.width, height: trailingFrame.minY - leadingFrame.maxY)
            }
        }

        /// The greatest alpha, 0 to 255, that the split view's layer tree holds in `rect` (in the split view's
        /// coordinates, all of it when `nil`) — its own drawing, the panes being transparent — as the window server
        /// composites it.
        ///
        /// The layer is rendered with Core Animation's own renderer, which takes the contents AppKit last committed for
        /// it, as the window server does. `render(in:)` would not do: AppKit's backing layer contents draw the view
        /// again for it, so a layer that was never redrawn renders as if it had been. The renderer needs a layer
        /// outside any tree, so the split view's is taken out of the window's for the call and put back after, and
        /// AppKit draws it again at its next display: render once per fixture, after the change under test.
        func renderedMaximumAlpha(in rect: NSRect? = nil) throws -> UInt8 {
            CATransaction.flush()
            let layer = try #require(splitView.layer)
            let superlayer = try #require(layer.superlayer)
            let layerIndex = try #require(superlayer.sublayers?.firstIndex { $0 === layer })
            let previousFrame = layer.frame
            let width = Int(layer.bounds.width)
            let height = Int(layer.bounds.height)

            let device = try #require(MTLCreateSystemDefaultDevice())
            let commandQueue = try #require(device.makeCommandQueue())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            descriptor.storageMode = .managed
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let transparentPixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: transparentPixels, bytesPerRow: width * 4)
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let renderer = CARenderer(mtlTexture: texture, options: [
                kCARendererColorSpace as String: colorSpace,
                kCARendererMetalCommandQueue as String: commandQueue,
            ])

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: width, height: height)
            root.addSublayer(layer)
            layer.frame = root.bounds
            // Given to the renderer before the commit, or the commit does not reach it and nothing is drawn.
            renderer.layer = root
            renderer.bounds = root.bounds
            CATransaction.commit()
            CATransaction.flush()
            defer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeFromSuperlayer()
                superlayer.insertSublayer(layer, at: UInt32(layerIndex))
                layer.frame = previousFrame
                CATransaction.commit()
                CATransaction.flush()
            }

            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(root.bounds)
            renderer.render()
            renderer.endFrame()

            let commandBuffer = try #require(commandQueue.makeCommandBuffer())
            let blitEncoder = try #require(commandBuffer.makeBlitCommandEncoder())
            blitEncoder.synchronize(resource: texture)
            blitEncoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            // The split view comes out upside down here: row `r` holds its y `height − 1 − r` (measured with three
            // stacked panes, macOS 27.2).
            let sampledRect = (rect ?? splitView.bounds).intersection(splitView.bounds).integral
            var maximumAlpha: UInt8 = 0
            for row in max(0, height - Int(sampledRect.maxY)) ..< min(height, height - Int(sampledRect.minY)) {
                for column in max(0, Int(sampledRect.minX)) ..< min(width, Int(sampledRect.maxX)) {
                    // Blue, green, red, alpha.
                    maximumAlpha = max(maximumAlpha, pixels[(row * width + column) * 4 + 3])
                }
            }
            return maximumAlpha
        }

        /// What the window does at the end of a run loop turn, then the Core Animation commit.
        func layoutAndDisplay() {
            splitView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        func tearDown() {
            window.orderOut(nil)
        }
    }

    /// The editor area's delegate (`EditorAreaViewController`): no pane narrower than 200 points while a divider is
    /// dragged.
    final class MinimumPaneExtentDelegate: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            proposedMinimumPosition + 200 + splitView.dividerThickness
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            proposedMaximumPosition - 200
        }
    }
}
