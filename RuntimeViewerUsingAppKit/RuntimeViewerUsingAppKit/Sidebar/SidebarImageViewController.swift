//
//  SidebarImageViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerApplication

class SidebarImageViewController: UXKitViewController<SidebarImageViewModel> {
    let tabView = NSTabView()

    let imageNotLoadedView = ImageLoadableView()

    let imageLoadingView = ImageLoadingView()

    let imageLoadedView = ImageLoadedView()

    let imageLoadErrorView = ImageLoadableView()

    let filterSearchField = FilterSearchField()

    let bottomSeparatorView = NSBox()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            tabView
            bottomSeparatorView
            filterSearchField
        }

        tabView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(bottomSeparatorView.snp.top)
        }

        bottomSeparatorView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.bottom.equalTo(filterSearchField.snp.top).offset(-5)
            make.height.equalTo(1)
        }

        filterSearchField.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview().inset(5)
        }

        bottomSeparatorView.do {
            $0.boxType = .separator
        }

        tabView.do {
            $0.addTabViewItem(NSTabViewItem(view: imageNotLoadedView, loadState: .notLoaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadingView, loadState: .loading))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadedView, loadState: .loaded))
            $0.addTabViewItem(NSTabViewItem(view: imageLoadErrorView, loadState: .loadError(Optional.none)))
            $0.tabViewType = .noTabsNoBorder
            $0.tabPosition = .none
            $0.tabViewBorderType = .none
        }
    }

    override func setupBindings(for viewModel: SidebarImageViewModel) {
        super.setupBindings(for: viewModel)

        let input = SidebarImageViewModel.Input(
            runtimeObjectClicked: imageLoadedView.tableView.rx.modelSelected().asSignal(),
            loadImageClicked: Signal.of(
                imageNotLoadedView.loadImageButton.rx.click.asSignal(),
                imageLoadErrorView.loadImageButton.rx.click.asSignal()
            ).merge(),
            searchString: filterSearchField.rx.stringValue.asSignal()
        )

        let output = viewModel.transform(input)

        output.runtimeObjects.drive(imageLoadedView.tableView.rx.items) { tableView, _, _, item in
            let cellView = tableView.box.makeView(ofClass: SidebarImageCellView.self, owner: nil)
            cellView.bind(to: item)
            return cellView
        }
        .disposed(by: rx.disposeBag)

        output.errorText.drive(imageLoadErrorView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.notLoadedText.drive(imageNotLoadedView.titleLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.emptyText.drive(imageLoadedView.emptyLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.isEmpty.not().drive(imageLoadedView.emptyLabel.rx.isHidden).disposed(by: rx.disposeBag)

        output.loadState.driveOnNextMainActor { [weak self] loadState in
            guard let self else { return }
            tabView.selectTabViewItem(withIdentifier: loadState.tabViewItemIdentifier)
        }
        .disposed(by: rx.disposeBag)
    }
}

extension Void?: Error {}

extension RuntimeImageLoadState {
    var tabViewItemIdentifier: String {
        switch self {
        case .notLoaded:
            return "notLoaded"
        case .loading:
            return "loading"
        case .loaded:
            return "loaded"
        case .loadError:
            return "loadError"
        }
    }
}

class SidebarImageCellView: ImageTextTableCellView {
    func bind(to viewModel: SidebarImageCellViewModel) {
        rx.disposeBag = DisposeBag()
        viewModel.$icon.asDriver().drive(_imageView.rx.image).disposed(by: rx.disposeBag)
        viewModel.$name.asDriver().drive(_textField.rx.attributedStringValue).disposed(by: rx.disposeBag)
    }
}

extension SidebarImageViewController {
    class ImageLoadedView: XiblessView {
        let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

        let emptyLabel = Label()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            hierarchy {
                scrollView
                emptyLabel
            }

            scrollView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }

            emptyLabel.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.left.right.equalToSuperview().inset(15)
            }

            emptyLabel.do {
                $0.alignment = .center
            }
        }
    }

    class ImageLoadingView: XiblessView {
        let loadingIndicator: MaterialLoadingIndicator = .init(radius: 25, color: .controlAccentColor)

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                loadingIndicator
            }

            loadingIndicator.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.size.equalTo(50)
            }

            loadingIndicator.startAnimating()
        }
    }

    class ImageLoadableView: XiblessView {
        let titleLabel = Label()

        let loadImageButton = PushButton()

        lazy var contentView = VStackView(alignment: .vStackCenter, spacing: 10) {
            titleLabel
                .gravity(.center)
            loadImageButton
                .gravity(.center)
        }

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            hierarchy {
                contentView
            }

            contentView.snp.makeConstraints { make in
                make.center.equalToSuperview()
                make.width.equalTo(200)
            }

            titleLabel.do {
                $0.isSelectable = true
                $0.alignment = .center
            }

            loadImageButton.do {
                $0.title = "Load now"
            }
        }
    }
}

extension NSTabViewItem {
    convenience init(view: NSView, loadState: RuntimeImageLoadState) {
        self.init(identifier: loadState.tabViewItemIdentifier)
        let vc = NSViewController()
        vc.view = view
        self.viewController = vc
    }
}
