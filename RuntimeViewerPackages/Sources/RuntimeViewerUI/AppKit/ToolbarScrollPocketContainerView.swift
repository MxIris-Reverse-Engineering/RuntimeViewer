#if os(macOS)

import AppKit
import SnapKit
import UIFoundation

/// A container whose content runs under the toolbar, with one scroll edge effect over the toolbar's strip laid in
/// front of all of it — what Xcode 27.2 lays over its editor area (`-[IDEEditorAreaContainer initWithFrame:]`,
/// IDEKit `0x10AF50`, a `DVTEdgeOcclusionView`; RE notes "Content under the toolbar").
///
/// Each scroll view under the title bar has a top scroll pocket of its own, but AppKit blurs every such pocket from
/// one capture, taken when the first of them is drawn: in an editor split in two, the toolbar over everything after
/// the first pane's text — that pane's minimap, which is drawn over its pocket, and the whole second pane — showed the
/// window's background, flat (measured on macOS 27.2). The pocket here is drawn after all the content, so its one
/// capture holds every pane, minimaps included, and it is in a backdrop group of its own, apart from the one the
/// panes' pockets share.
///
/// The pocket is hard, as Xcode's: the content blurred under a near-opaque replay of the background, which its capture
/// view takes from behind the content. It is as tall as the container's top safe area — the toolbar — and has none
/// when the toolbar is hidden. Before macOS 26, which has no scroll pockets, the container only holds its content.
@MainActor
public final class ToolbarScrollPocketContainerView: NSView {
    public let contentView: NSView

    /// The edge effect over the toolbar's strip: in front of the content, its capture view at the back.
    private let toolbarScrollPocketView: ScrollPocketView?

    public init(contentView: NSView) {
        self.contentView = contentView
        if #available(macOS 26.0, *) {
            toolbarScrollPocketView = ScrollPocketView(edge: .top)
        } else {
            toolbarScrollPocketView = nil
        }
        super.init(frame: .zero)

        if let captureView = toolbarScrollPocketView?.captureView {
            addSubview(captureView)
            Self.pinToToolbarStrip(captureView)
        }
        addSubview(contentView)
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        if let toolbarScrollPocketView {
            addSubview(toolbarScrollPocketView)
            Self.pinToToolbarStrip(toolbarScrollPocketView)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// From the container's top edge down to its top safe area, across its whole width.
    private static func pinToToolbarStrip(_ view: NSView) {
        view.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.superview!.safeAreaLayoutGuide.snp.top)
        }
    }
}

#endif
