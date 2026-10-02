import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import DependenciesMacros

final class AttachToProcessViewController: BaseViewController<AttachToProcessViewModel> {
    /// Which machine's processes this sheet offers.
    ///
    /// Not a style choice: the two cases list different machines, and showing this Mac's
    /// applications beside a device's processes would invite picking a local pid to inject
    /// into a phone. So the device case replaces the picker rather than adding a tab to it.
    enum Target {
        /// Processes on this Mac, including the simulator and any process Runtime Viewer
        /// has already injected. Enumerated locally, exactly as before.
        case hostProcesses

        /// Processes on the machine the selected engine belongs to, listed by that machine.
        case remoteProcesses(RemoteProcessItemSource)
    }

    override var shouldDisplayCommonLoading: Bool { true }

    private let target: Target

    private let pickerViewController: RunningPickerTabViewController

    private let attachRelay = PublishRelay<any RunningItem>()

    private let cancelRelay = PublishRelay<Void>()

    private let loadFailureRelay = PublishRelay<any Error>()

    init(target: Target, viewModel: AttachToProcessViewModel? = nil) {
        self.target = target
        switch target {
        case .hostProcesses:
            let applicationConfiguration = RunningPickerTabViewController.ApplicationConfiguration(
                style: .list,
                title: "Attach To Application",
                description: "Select a running application to attach to",
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Attach"
            )
            let processConfiguration = RunningPickerTabViewController.ProcessConfiguration(
                style: .list,
                title: "Attach To Process",
                description: "Select a running process to attach to",
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Attach"
            )
            self.pickerViewController = RunningPickerTabViewController(
                applicationConfiguration: applicationConfiguration,
                processConfiguration: processConfiguration
            )
        case .remoteProcesses(let itemSource):
            // One tab, so the tab bar is gone and the device's process list is hosted
            // directly. The Applications tab is dropped rather than left empty: it can only
            // ever show this Mac's applications, which are not attachable targets here.
            //
            // Fields: no icon (there is none to fetch across the connection), no platform
            // (every process on one device shares it), no sandbox column (not reported).
            let processConfiguration = RunningPickerTabViewController.ProcessConfiguration(
                style: .list,
                title: "Attach To Process on \(itemSource.machineName)",
                description: "Select a process on \(itemSource.machineName) to attach to",
                cancelButtonTitle: "Cancel",
                confirmButtonTitle: "Attach",
                allowsFields: [.name, .pid, .executablePath]
            )
            self.pickerViewController = RunningPickerTabViewController(
                configuration: .init(tabs: [.processes]),
                processConfiguration: processConfiguration,
                processItemSource: itemSource.makeItemSource()
            )
        }
        super.init(viewModel: viewModel)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            pickerViewController
        }

        pickerViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        pickerViewController.delegate = self
    }

    override func setupBindings(for viewModel: AttachToProcessViewModel) {
        super.setupBindings(for: viewModel)

        let input = AttachToProcessViewModel.Input(
            attachToProcess: attachRelay.asSignal(),
            processListFailed: loadFailureRelay.asSignal(),
            cancel: cancelRelay.asSignal()
        )

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

    /// Only the far end can say whether one of its processes is injectable, so for a device
    /// list this is where its verdict is applied. Returning `false` both refuses the
    /// selection and dims the row, so a target that cannot be injected reads as
    /// unavailable instead of failing after the pick.
    ///
    /// The host list keeps answering `true`: the library already refuses pid 0 and pid 1,
    /// and nothing else about a local process is known to rule it out before trying.
    func runningPickerTabViewController(_ viewController: RunningPickerTabViewController, shouldSelectProcess process: RunningProcess) -> Bool {
        switch target {
        case .hostProcesses:
            return true
        case .remoteProcesses(let itemSource):
            return itemSource.isInjectable(processIdentifier: process.processIdentifier)
        }
    }

    /// A device that could not produce its process list leaves the picker empty, which on
    /// its own is indistinguishable from a device with nothing to list.
    func runningPickerTabViewController(_ viewController: RunningPickerTabViewController, didFailToLoadProcesses error: any Error) {
        loadFailureRelay.accept(error)
    }

    func runningPickerTabViewControllerWasCancelled(_ viewController: RunningPickerTabViewController) {
        cancelRelay.accept()
    }
}
