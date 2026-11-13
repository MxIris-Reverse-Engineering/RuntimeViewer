// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import Testing
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge

/// The editor's scroll view under a full-size-content toolbar, as an editor pane at the top of the
/// window puts it: AppKit gives it a top scroll pocket over the toolbar, which is what shows the
/// interface blurred there instead of plainly (proposal
/// `editor-content-under-toolbar-scroll-pocket`).
///
/// The pocket is found among the scroll view's subviews by its class name, `NSScrollPocket`:
/// UIFoundation's `NSScrollView.box.scrollPocket(on:)` cannot be used here, because this bundle sees
/// the SourceEditor modules, which declare AppKit's private `NSScrollViewDelegate` differently from
/// UIFoundation's Apple-internal module (`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md`).
@Suite("ScrollPocketUnderToolbar", .serialized)
@MainActor
struct ScrollPocketUnderToolbarTests {
    @Test
    func theScrollViewHasATopPocketAsTallAsTheToolbar() throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try Fixture(showsMinimap: false)

        let topPocket = try #require(fixture.topScrollPocket)
        #expect(fixture.toolbarDepth > 0)
        #expect(topPocket.frame.height == fixture.toolbarDepth)
    }

    /// The reconstruction adds the minimap as a margin overlay straight into the scroll view and
    /// frames it the scroll view's full height (`ContentViewLayoutContainer.layoutMarginAccessories`,
    /// 27.2.0-alpha.2), and it lands above the top pocket in the scroll view's subviews. So with the
    /// minimap on, an editor alone under a toolbar draws it plainly over the toolbar instead of
    /// blurred. The app does not show this: its editor area lays one pocket over the toolbar's strip
    /// in front of every pane, minimap included (`ToolbarScrollPocketContainerView`). A fix in the
    /// editor itself belongs to the reconstruction; when one arrives, this known issue stops being
    /// recorded and the test fails until `withKnownIssue` is removed.
    @Test
    func theMinimapIsDrawnBelowTheTopPocket() throws {
        guard #available(macOS 26.0, *) else { return }
        let fixture = try Fixture(showsMinimap: true)

        let subviews = fixture.scrollView.subviews
        let topPocket = try #require(fixture.topScrollPocket)
        let topPocketIndex = try #require(subviews.firstIndex { $0 === topPocket })
        let minimapIndex = try #require(subviews.firstIndex { String(describing: type(of: $0)) == "MinimapView" })
        withKnownIssue("The reconstruction puts the minimap above the scroll view's top pocket") {
            #expect(minimapIndex < topPocketIndex)
        }
    }

    /// The bridge's editor view filling the content view of a window whose toolbar overlaps it, with
    /// the top inset handed over as `ContentSourceEditorViewController` does.
    @MainActor
    private struct Fixture {
        let window: NSWindow

        let scrollView: NSScrollView

        /// How far the toolbar overlaps the editor.
        let toolbarDepth: CGFloat

        init(showsMinimap: Bool) throws {
            let bridge = SourceEditorBridge()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.toolbar = NSToolbar(identifier: "ScrollPocketUnderToolbarTests")
            window.toolbarStyle = .unified
            let hostView = NSView()
            window.contentView = hostView
            let editorView = bridge.editorView
            editorView.translatesAutoresizingMaskIntoConstraints = false
            hostView.addSubview(editorView)
            NSLayoutConstraint.activate([
                editorView.topAnchor.constraint(equalTo: hostView.topAnchor),
                editorView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
                editorView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
                editorView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            ])
            window.orderFront(nil)

            bridge.applyDisplayOptions(
                showsLineNumbers: true,
                showsFoldingRibbon: true,
                showsStickyHeaders: true,
                showsMinimap: showsMinimap,
                showsScopeGuides: false,
                showsInvisibles: false,
                showsMarkSeparators: false,
                showsInsertionPoint: false
            )
            let members = (0 ..< 200).map { "    var property\($0): Int" }.joined(separator: "\n")
            bridge.setSource(
                "class Widget {\n" + members + "\n}\n",
                languageIdentifier: "swift",
                semanticRanges: [],
                semanticNodeTypeNames: [],
                commentDecorations: nil,
                restoresScrollPosition: true
            )
            Self.layout(window)
            toolbarDepth = hostView.safeAreaInsets.top
            bridge.applyTopContentInset(toolbarDepth)
            Self.layout(window)

            scrollView = try #require(editorView as? SourceEditorView).scrollView
        }

        /// The pocket along the scroll view's top edge.
        var topScrollPocket: NSView? {
            scrollView.subviews.first { subview in
                String(describing: type(of: subview)) == "NSScrollPocket" && subview.frame.minY == scrollView.bounds.minY
            }
        }

        /// Lays the window out and lets the CoreAnimation transaction commit, which is when AppKit
        /// places the pockets.
        private static func layout(_ window: NSWindow) {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.begin()
            CATransaction.flush()
            CATransaction.commit()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }
}

#endif
