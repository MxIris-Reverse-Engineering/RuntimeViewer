import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootTableCellView: ImageTextTableCellView {
    override func setup() {
        super.setup()
        
        _imageView.contentTintColor = .controlAccentColor
    }

    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.$appearance.asDriver().driveOnNext { [weak self] appearance in
            guard let self else { return }
            _imageView.image = appearance.icon
            _textField.attributedStringValue = appearance.name
        }
        .disposed(by: rx.disposeBag)
    }
}
