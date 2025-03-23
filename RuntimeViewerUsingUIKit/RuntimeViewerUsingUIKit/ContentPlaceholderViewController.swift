#if canImport(UIKit)

import UIKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentPlaceholderViewController: ViewController<ContentPlaceholderViewModel> {
    let placeholerLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        if #available(iOS 17.0, tvOS 17.0, *) {
            var contentUnavailableConfiguration = UIContentUnavailableConfiguration.empty()
            contentUnavailableConfiguration.text = "Select a runtime object"
            contentUnavailableConfiguration.textProperties.font = .systemFont(ofSize: 25, weight: .regular)
            contentUnavailableConfiguration.textProperties.color = .secondaryLabel
            contentUnavailableConfiguration.button = .bordered()
            contentUnavailableConfiguration.button.title = "Reload Data"
            contentUnavailableConfiguration.buttonProperties.primaryAction = .init(handler: { _ in

                let appDelegate = UIApplication.shared.delegate as! AppDelegate
                appDelegate.remoteRuntimeEngine?.reloadData()
            })
            
            self.contentUnavailableConfiguration = contentUnavailableConfiguration
        } else {
            hierarchy {
                placeholerLabel
            }

            placeholerLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
            }

            placeholerLabel.do {
                $0.text = "Select a runtime object"
                $0.font = .systemFont(ofSize: 25, weight: .regular)
                $0.textColor = .secondaryLabel
            }
        }
    }
}

#endif
