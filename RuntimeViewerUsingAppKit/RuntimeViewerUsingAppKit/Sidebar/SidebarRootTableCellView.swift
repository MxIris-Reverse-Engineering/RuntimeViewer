import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootTableCellView: ImageTextTableCellView {
    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
