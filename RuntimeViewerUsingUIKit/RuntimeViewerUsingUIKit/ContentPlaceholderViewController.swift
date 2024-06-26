#if canImport(UIKit)

import UIKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentPlaceholderViewController: ViewController<ContentPlaceholderViewModel> {
    let placeholerLabel = UILabel()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        hierarchy {
            placeholerLabel
        }
        
        placeholerLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        placeholerLabel.do {
            $0.text = "Select a runtime object"
            $0.font = .systemFont(ofSize: 20, weight: .regular)
            $0.textColor = .secondaryLabel
        }
    }
}

#endif
