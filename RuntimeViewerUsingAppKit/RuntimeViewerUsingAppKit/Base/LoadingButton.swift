import AppKit
import RuntimeViewerUI
import SnapKit

/// `PushButton` subclass that swaps its title for a small spinner while
/// `isLoading == true`. AppKit's `isEnabled = false` during loading also
/// suppresses clicks, so the call site does not need to gate the action
/// separately.
///
/// Used by the specialization sheet's per-row "Choose Type…" button: the
/// row's view model flips `isLoading` while the type-picker payload (sort +
/// box construction) runs on a background queue, so the user sees inline
/// feedback on the button itself instead of a main-thread freeze.
final class LoadingButton: PushButton {
    private let spinner = NSProgressIndicator()
    private var titleBeforeLoading: NSAttributedString?

    var isLoading: Bool = false {
        didSet {
            guard isLoading != oldValue else { return }
            applyLoadingState()
        }
    }

    override func setup() {
        super.setup()

        spinner.do {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isIndeterminate = true
            $0.isDisplayedWhenStopped = false
            $0.isHidden = true
        }
        addSubview(spinner)
        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
    }

    private func applyLoadingState() {
        if isLoading {
            titleBeforeLoading = attributedTitle
            attributedTitle = NSAttributedString()
            isEnabled = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            if let titleBeforeLoading {
                attributedTitle = titleBeforeLoading
            }
            titleBeforeLoading = nil
            isEnabled = true
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }
}
