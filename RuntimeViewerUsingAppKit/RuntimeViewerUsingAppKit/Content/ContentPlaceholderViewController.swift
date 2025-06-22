import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class ContentPlaceholderViewController: UXKitViewController<ContentPlaceholderViewModel> {
    let placeholderLabel = Label("Select a runtime object")

    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            placeholderLabel
        }

        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        placeholderLabel.do {
            $0.font = .systemFont(ofSize: 20, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        view.window?.title = "Runtime Viewer"
        view.window?.subtitle = ""
    }
}
