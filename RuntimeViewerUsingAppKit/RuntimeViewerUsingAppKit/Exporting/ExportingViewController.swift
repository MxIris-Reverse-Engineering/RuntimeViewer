import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

protocol ExportingStepViewModel: ViewModelProtocol {
    var title: Driver<String> { get }
    var previousTitle: Driver<String> { get }
    var nextTitle: Driver<String> { get }
    var isNextEnabled: Driver<Bool> { get }
    var isPreviousEnabled: Driver<Bool> { get }
}

extension ExportingStepViewModel {
    var previousTitle: Driver<String> {
        "Previous"
    }

    var nextTitle: Driver<String> {
        "Next"
    }
}

protocol ExportingStepViewController<ViewModel>: NSViewController {
    associatedtype ViewModel: ExportingStepViewModel

    var viewModel: ViewModel? { get }
}

final class ExportingWindowController: XiblessWindowController<NSWindow> {}

final class ExportingViewController: XiblessViewController<NSView> {
    fileprivate let tabViewController = NSTabViewController()

    private let titleLabel = Label()

    private let cancelButton = PushButton(title: "Cancel", titleFont: .systemFont(ofSize: 13))

    private let nextButton = PushButton(title: "Next", titleFont: .systemFont(ofSize: 13))

    private let previousButton = PushButton(title: "Previous", titleFont: .systemFont(ofSize: 13))

    private let router: any Router<ExportingRoute>

    private let navigationComponentsDisposeBag = DisposeBag()
    
    init(router: any Router<ExportingRoute>) {
        self.router = router
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            titleLabel
            tabViewController
            cancelButton
            nextButton
            previousButton
        }

        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        tabViewController.view.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(20)
        }

        cancelButton.snp.makeConstraints { make in
            make.leading.bottom.equalToSuperview().inset(20)
            make.width.equalTo(75)
        }

        nextButton.snp.makeConstraints { make in
            make.top.equalTo(tabViewController.view.snp.bottom).offset(20)
            make.trailing.bottom.equalToSuperview().inset(20)
            make.width.equalTo(75)
        }

        previousButton.snp.makeConstraints { make in
            make.centerY.equalTo(nextButton)
            make.trailing.equalTo(nextButton.snp.leading).offset(-12)
            make.width.equalTo(75)
        }

        tabViewController.do {
            $0.tabStyle = .unspecified
            $0.view.wantsLayer = true
            $0.view.layer?.do {
                $0.borderWidth = 1
                $0.borderColor = NSColor(light: .black.withAlphaComponent(0.1), dark: .white.withAlphaComponent(0.1)).cgColor
            }
        }

        titleLabel.do {
            $0.textColor = .controlTextColor
            $0.font = .systemFont(ofSize: 13)
        }

        cancelButton.rx.click.asSignal().emit(to: router.rx.trigger(.cancel)).disposed(by: navigationComponentsDisposeBag)
        previousButton.rx.click.asSignal().emit(to: router.rx.trigger(.previous)).disposed(by: navigationComponentsDisposeBag)
        nextButton.rx.click.asSignal().emit(to: router.rx.trigger(.next)).disposed(by: navigationComponentsDisposeBag)

        
        nextButton.do {
            $0.keyEquivalent = "\r"
        }

        cancelButton.do {
            $0.keyEquivalent = "\u{1b}"
        }
        
        preferredContentSize = NSSize(width: 745, height: 450)
    }

    func setupBinding(for viewModel: any ExportingStepViewModel) {
        rx.disposeBag = DisposeBag()

        viewModel.title.drive(titleLabel.rx.stringValue).disposed(by: rx.disposeBag)
        viewModel.previousTitle.drive(previousButton.rx.title).disposed(by: rx.disposeBag)
        viewModel.nextTitle.drive(nextButton.rx.title).disposed(by: rx.disposeBag)
        viewModel.isPreviousEnabled.drive(previousButton.rx.isEnabled).disposed(by: rx.disposeBag)
        viewModel.isNextEnabled.drive(nextButton.rx.isEnabled).disposed(by: rx.disposeBag)
    }
}

extension Transition where ViewController: ExportingViewController {
    static func select(index: Int) -> Self {
        Self(presentables: []) { windowController, viewController, options, completion in
            viewController?.tabViewController.selectedTabViewItemIndex = index
            if let stepViewController = viewController?.tabViewController.tabViewItems[index].viewController as? (any ExportingStepViewController), let viewModel = stepViewController.viewModel {
                viewController?.setupBinding(for: viewModel)
            }
            completion?()
        }
    }

    static func set(_ presentables: [Presentable]) -> Self {
        Self(presentables: presentables) { windowController, viewController, options, completion in
            guard let viewController = viewController ?? ((windowController as? NSWindowController)?.contentViewController as? ViewController) else {
                completion?()
                return
            }
            viewController.tabViewController.tabViewItems.forEach { viewController.tabViewController.removeTabViewItem($0) }
            presentables.compactMap { $0.viewController }.forEach { viewController.tabViewController.addTabViewItem(NSTabViewItem(viewController: $0)) }
            completion?()
        }
    }
}
