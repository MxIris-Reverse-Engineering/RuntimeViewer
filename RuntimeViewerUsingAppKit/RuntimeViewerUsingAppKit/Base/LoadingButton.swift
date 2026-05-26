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
open class LoadingButton: PushButton {
    private struct ButtonConfiguration {
        let attributedTitle: NSAttributedString
        let attributedAlternateTitle: NSAttributedString
        let image: NSImage?
        let alternateImage: NSImage?

        static let empty = ButtonConfiguration(attributedTitle: .init(), attributedAlternateTitle: .init(), image: nil, alternateImage: nil)
    }

    private let spinner = NSProgressIndicator()

    private var beforeButtonConfiguration: ButtonConfiguration = .empty

    public var isLoading: Bool = false {
        didSet {
            guard isLoading != oldValue else { return }
            applyLoadingState(isLoading)
        }
    }

    open override func setup() {
        super.setup()

        addSubview(spinner)

        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        spinner.do {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isIndeterminate = true
            $0.isDisplayedWhenStopped = false
            $0.isHidden = true
        }
    }

    private func makeButtonConfiguration() -> ButtonConfiguration {
        ButtonConfiguration(
            attributedTitle: attributedTitle,
            attributedAlternateTitle: attributedAlternateTitle,
            image: image,
            alternateImage: alternateImage,
        )
    }

    private func applyButtonConfiguration(_ configuration: ButtonConfiguration) {
        attributedTitle = configuration.attributedTitle
        attributedAlternateTitle = configuration.attributedAlternateTitle
        image = configuration.image
        alternateImage = configuration.alternateImage
    }

    private func applyLoadingState(_ isLoading: Bool) {
        if isLoading {
            beforeButtonConfiguration = makeButtonConfiguration()
            applyButtonConfiguration(.empty)
            isEnabled = false
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            applyButtonConfiguration(beforeButtonConfiguration)
            isEnabled = true
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }
}
