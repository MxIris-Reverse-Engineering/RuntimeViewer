import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class InspectorPlaceholderViewController: UXEffectViewController<InspectorPlaceholderViewModel> {
    private let placeholderLabel = Label("No Selection")

    override var contentViewUsingSafeArea: Bool { true }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        contentView.hierarchy {
            placeholderLabel
        }

        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        placeholderLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }
}
