import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class AttachToProcessViewController: AppKitViewController<AttachToProcessViewModel> {
    let pickerViewController: RunningApplicationPickerViewController

    let attachRelay = PublishRelay<NSRunningApplication>()

    let cancelRelay = PublishRelay<Void>()

    override init(viewModel: AttachToProcessViewModel? = nil) {
        let configuration = RunningApplicationPickerViewController.Configuration(title: "Attach To Process", description: "Select a running application to attach to", cancelButtonTitle: "Cancel", confirmButtonTitle: "Attach")
        self.pickerViewController = RunningApplicationPickerViewController(configuration: configuration)
        super.init(viewModel: viewModel)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            pickerViewController
        }

        pickerViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        pickerViewController.delegate = self
    }

    override func setupBindings(for viewModel: AttachToProcessViewModel) {
        super.setupBindings(for: viewModel)

        let input = AttachToProcessViewModel.Input(attachToProcess: attachRelay.asSignal(), cancel: cancelRelay.asSignal())

        _ = viewModel.transform(input)
    }
}

extension AttachToProcessViewController: RunningApplicationPickerViewController.Delegate {
    func runningApplicationPickerViewController(_ viewController: RunningApplicationPickerViewController, didConfirmApplication application: NSRunningApplication) {
        attachRelay.accept(application)
    }

    func runningApplicationPickerViewControllerWasCancel(_ viewController: RunningApplicationPickerViewController) {
        cancelRelay.accept(())
    }
}
