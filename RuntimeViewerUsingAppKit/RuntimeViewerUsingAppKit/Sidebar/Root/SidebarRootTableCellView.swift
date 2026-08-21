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

        addSubview(iconView)
        addSubview(titleLabel)

        iconView.makeConstraints { make in
            make.leftAnchor.constraint(equalTo: leftAnchor)
            make.centerYAnchor.constraint(equalTo: centerYAnchor)
        }

        titleLabel.makeConstraints { make in
            make.leftAnchor.constraint(equalTo: iconView.rightAnchor, constant: 10)
            make.centerYAnchor.constraint(equalTo: centerYAnchor)
            make.rightAnchor.constraint(lessThanOrEqualTo: rightAnchor)
        }

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.maximumNumberOfLines = 1
        
        iconView.contentTintColor = .controlAccentColor
        
    }

    func bind(to viewModel: SidebarRootCellViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.$appearance.asDriver().driveOnNext { [weak self] appearance in
            guard let self else { return }
            iconView.image = appearance.icon
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
