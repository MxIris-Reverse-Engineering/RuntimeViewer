import AppKit
import RuntimeViewerApplication
import RuntimeViewerUI
import RuntimeViewerArchitectures

class CommonLoadingView: XiblessView {
    public var isRunning: Bool = false {
        didSet {
            if isRunning {
                loadingIndicator.startAnimating()
                isHidden = false
            } else {
                loadingIndicator.stopAnimating()
                isHidden = true
            }
        }
    }

    private let contentView = NSVisualEffectView()

    private let loadingIndicator: MaterialLoadingIndicator = .init(radius: 25, color: .controlAccentColor)

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)

        hierarchy {
            contentView.hierarchy {
                loadingIndicator
            }
        }

        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(50)
        }

        loadingIndicator.lineWidth = 5
    }
}
