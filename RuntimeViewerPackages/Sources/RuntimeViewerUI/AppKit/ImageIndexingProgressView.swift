#if os(macOS)

import AppKit
import SnapKit
import UIFoundation

/// The progress of an image being indexed: a bar, the phase under way and how many items of it are
/// done, centred in the view's safe area. The sidebar's object page shows it while it opens an
/// image, and an editor pane while it indexes an image chosen in its jump bar (proposal
/// `editor-jump-bar`), so both look the same.
public final class ImageIndexingProgressView: XiblessView {
    public let progressIndicator = NSProgressIndicator()

    public let descriptionLabel = Label()

    public let countLabel = Label()

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)

        let contentStack = VStackView(alignment: .center, spacing: 8) {
            progressIndicator
            descriptionLabel
            countLabel
        }

        hierarchy {
            contentStack
        }

        // The safe area: from macOS 26 the view runs under the toolbar and the bars over it.
        contentStack.snp.makeConstraints { make in
            make.center.equalTo(safeAreaLayoutGuide)
        }

        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(260)
        }

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0

        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.alignment = .center

        countLabel.textColor = .tertiaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .center
    }

    /// Shows `fraction` of the work done, the phase under way, and its count — empty while the
    /// phase counts nothing.
    public func show(fraction: Double, description: String, itemCount: String) {
        progressIndicator.doubleValue = fraction
        descriptionLabel.stringValue = description
        countLabel.stringValue = itemCount
    }
}

#endif
