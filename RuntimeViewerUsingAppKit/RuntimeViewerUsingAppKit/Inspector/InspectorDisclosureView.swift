import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class InspectorDisclosureView<ContentView: NSView>: XiblessView {
    private final class HeaderView: XiblessView {
        let titleLabel = Label()

        let disclosureButton = Button()

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                titleLabel
                disclosureButton
            }

            // Nothing above the title and the button, and 8 points in from the sides, as the headers
            // of the inspector's other pages: the view sits at the top of the Class page, which starts
            // its content at its top edge, below the gap the tab switcher leaves
            // (`TabViewController.pageTopSpacing`).
            titleLabel.snp.makeConstraints { make in
                make.top.equalToSuperview()
                make.left.equalToSuperview().inset(8)
                make.bottom.equalToSuperview()
            }

            disclosureButton.snp.makeConstraints { make in
                make.top.equalToSuperview()
                make.right.equalToSuperview().inset(8)
                make.left.greaterThanOrEqualTo(titleLabel.snp.right).offset(15)
            }

            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: 12, weight: .bold)

            disclosureButton.title = "Hide"
            disclosureButton.alternateTitle = "Show"
            disclosureButton.setButtonType(.toggle)
            disclosureButton.contentTintColor = .secondaryLabelColor
            disclosureButton.font = .systemFont(ofSize: 12, weight: .bold)
            disclosureButton.isBordered = false
            disclosureButton.alphaValue = 0.0
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea(_:))

            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            disclosureButton.alphaValue = 1.0
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            disclosureButton.alphaValue = 0.0
        }
    }

    private let headerView: HeaderView

    let contentView: ContentView

    var title: String = "" {
        didSet {
            headerView.titleLabel.stringValue = title
        }
    }

    init(contentView: ContentView) {
        self.headerView = HeaderView()
        self.contentView = contentView

        super.init(frame: .zero)

        hierarchy {
            headerView
            contentView
        }

        headerView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
        }

        setupContentViewConstraints(for: headerView.disclosureButton.state)

        headerView.disclosureButton.box.setAction { [weak self] button in
            guard let self, let button else { return }
            setupContentViewConstraints(for: button.state)
        }
    }

    private func setupContentViewConstraints(for disclosureState: NSControl.StateValue) {
        contentView.snp.remakeConstraints { make in
            // 8 points below the title and edge to edge, as the lists below the headers of the
            // inspector's other pages: a list's inset style leaves its own margin.
            make.top.equalTo(headerView.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalToSuperview().inset(15)
            switch disclosureState {
            case .on:
                make.height.equalTo(0)
            default:
                break
            }
        }
        // Hidden as well as flattened: content that cannot shrink with it, such as a loading
        // placeholder, would otherwise draw on below the title.
        contentView.isHidden = disclosureState == .on
    }
}
