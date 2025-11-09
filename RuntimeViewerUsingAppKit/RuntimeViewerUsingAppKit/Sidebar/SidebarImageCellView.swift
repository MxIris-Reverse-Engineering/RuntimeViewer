import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

class SidebarImageCellView: ImageTextTableCellView {
    
    override func setup() {
        super.setup()
        
        _imageView.contentTintColor = .controlAccentColor
    }
    
    func bind(to viewModel: SidebarImageCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
