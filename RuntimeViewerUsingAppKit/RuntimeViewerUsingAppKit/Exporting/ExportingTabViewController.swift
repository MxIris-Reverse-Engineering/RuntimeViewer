import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingTabViewController: NSTabViewController {
    private let exportingState: ExportingState
    private let documentState: DocumentState
    private let router: any Router<MainRoute>

    private var selectionVM: ExportingSelectionViewModel!
    private var configurationVM: ExportingConfigurationViewModel!
    private var progressVM: ExportingProgressViewModel!

    private var disposeBag = DisposeBag()

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        self.documentState = documentState
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabStyle = .unspecified
        preferredContentSize = NSSize(width: 550, height: 450)

        // Step 1: Selection
        let selectionVC = ExportingSelectionViewController()
        selectionVM = ExportingSelectionViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        selectionVC.setupBindings(for: selectionVM)

        // Step 2: Configuration
        let configurationVC = ExportingConfigurationViewController()
        configurationVM = ExportingConfigurationViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        configurationVC.setupBindings(for: configurationVM)

        // Step 3: Progress
        let progressVC = ExportingProgressViewController()
        progressVM = ExportingProgressViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        progressVC.setupBindings(for: progressVM)

        // Add tab items
        addTabViewItem(NSTabViewItem(viewController: selectionVC))
        addTabViewItem(NSTabViewItem(viewController: configurationVC))
        addTabViewItem(NSTabViewItem(viewController: progressVC))

        selectedTabViewItemIndex = 0

        setupNavigationBindings()
    }

    private func setupNavigationBindings() {
        // Selection → Configuration
        selectionVM.nextRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            configurationVM.refreshFromState()
            selectedTabViewItemIndex = 1
        }
        .disposed(by: disposeBag)

        // Configuration → Selection (back)
        configurationVM.backRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            selectedTabViewItemIndex = 0
        }
        .disposed(by: disposeBag)

        // Configuration → Export (directory picker → Progress)
        configurationVM.exportClickedRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            presentDirectoryPicker()
        }
        .disposed(by: disposeBag)
    }

    private func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for exported interfaces"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            exportingState.destinationURL = url
            selectedTabViewItemIndex = 2
            progressVM.startExport()
        }
    }
}
