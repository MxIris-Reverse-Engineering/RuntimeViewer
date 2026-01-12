import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootTableCellView: ImageTextTableCellView {
    
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            print(backgroundStyle.rawValue)
            switch backgroundStyle {
            case .normal:
                _imageView.symbolConfiguration = .init(hierarchicalColor: .controlAccentColor)
            case .emphasized:
                _imageView.symbolConfiguration = .preferringMonochrome()
            case .raised:
                _imageView.symbolConfiguration = .preferringMonochrome()
            case .lowered:
                _imageView.symbolConfiguration = .preferringMonochrome()
            @unknown default:
                break
            }
        }
    }
    
    override func setup() {
        super.setup()
        
    }
    
    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()
        
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}
