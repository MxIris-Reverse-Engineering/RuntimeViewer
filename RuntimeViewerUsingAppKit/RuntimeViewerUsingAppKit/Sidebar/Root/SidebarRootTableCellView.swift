import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class SidebarRootTableCellView: TableCellView {
    private let iconView = ImageView()
    private let titleLabel = Label()

    override func setup() {
        super.setup()
        
        hierarchy {
            iconView
            titleLabel
        }

        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(2)
            make.centerY.equalToSuperview()
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(4)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualToSuperview()
        }

        titleLabel.do {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.maximumNumberOfLines = 1
        }
        
    }

    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.$appearance.asDriver().driveOnNext { [weak self] appearance in
            guard let self else { return }
            iconView.image = appearance.icon
            // A template tinted per kind, as Xcode's navigator draws it; a selected row turns it white.
            iconView.contentTintColor = appearance.iconColor
            titleLabel.attributedStringValue = appearance.name
        }
        .disposed(by: rx.disposeBag)
    }
}

extension NSTableCellView {
    var rowView: NSTableRowView? {
        superview as? NSTableRowView
    }
}
