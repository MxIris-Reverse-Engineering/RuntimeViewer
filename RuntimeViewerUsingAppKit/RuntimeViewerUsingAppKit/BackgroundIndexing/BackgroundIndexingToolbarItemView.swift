import AppKit
import SnapKit

enum BackgroundIndexingToolbarState: Equatable {
    case idle
    case disabled
    case indexing
    case hasFailures
}

final class BackgroundIndexingToolbarItemView: NSView {
    private let iconView = NSImageView().then {
        $0.image = NSImage(systemSymbolName: "square.stack.3d.down.right",
                           accessibilityDescription: nil)
        $0.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        $0.contentTintColor = .secondaryLabelColor
    }
    private let spinner = NSProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .small
        $0.isIndeterminate = true
        $0.isDisplayedWhenStopped = false
    }
    private let failureDot = NSView()

    var state: BackgroundIndexingToolbarState = .idle {
        didSet { applyState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayout()
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        hierarchy {
            iconView
            spinner
            failureDot
        }
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(18)
        }
        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(14)
        }
        failureDot.snp.makeConstraints { make in
            make.width.height.equalTo(6)
            make.trailing.bottom.equalTo(iconView)
        }
        failureDot.wantsLayer = true
        failureDot.layer?.cornerRadius = 3
        failureDot.layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    private func applyState() {
        switch state {
        case .idle:
            iconView.contentTintColor = .secondaryLabelColor
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .disabled:
            iconView.contentTintColor = .tertiaryLabelColor
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .indexing:
            iconView.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = true
        case .hasFailures:
            iconView.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = false
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
}
