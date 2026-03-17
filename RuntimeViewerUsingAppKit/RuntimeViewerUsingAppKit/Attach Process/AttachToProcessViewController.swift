import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class AttachToProcessViewController: AppKitViewController<AttachToProcessViewModel> {
    private let pickerViewController: RunningPickerTabViewController

    private let attachRelay = PublishRelay<any RunningItem>()

    private let cancelRelay = PublishRelay<Void>()

    override init(viewModel: AttachToProcessViewModel? = nil) {
        let applicationConfiguration = RunningPickerTabViewController.ApplicationConfiguration(title: "Attach To Process", description: "Select a running application to attach to", cancelButtonTitle: "Cancel", confirmButtonTitle: "Attach")
        let processConfiguration = RunningPickerTabViewController.ProcessConfiguration(title: "Attach To Process", description: "Select a running application to attach to", cancelButtonTitle: "Cancel", confirmButtonTitle: "Attach")
        self.pickerViewController = RunningPickerTabViewController(applicationConfiguration: applicationConfiguration, processConfiguration: processConfiguration)
        super.init(viewModel: viewModel)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            pickerViewController
        }

        pickerViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 16, left: 0, bottom: 0, right: 0))
        }

        pickerViewController.delegate = self
    }

    override func setupBindings(for viewModel: AttachToProcessViewModel) {
        super.setupBindings(for: viewModel)

        let input = AttachToProcessViewModel.Input(attachToProcess: attachRelay.asSignal(), cancel: cancelRelay.asSignal())

        _ = viewModel.transform(input)
    }
}

extension AttachToProcessViewController: RunningPickerTabViewController.Delegate {
    func runningPickerTabViewController(_ viewController: RunningPickerTabViewController, didConfirmProcess process: RunningProcess) {
        attachRelay.accept(process)
    }

    func runningPickerTabViewController(_ viewController: RunningPickerTabViewController, didConfirmApplication application: RunningApplication) {
        attachRelay.accept(application)
    }

    func runningPickerTabViewControllerWasCancelled(_ viewController: RunningPickerTabViewController) {
        cancelRelay.accept()
    }
}
