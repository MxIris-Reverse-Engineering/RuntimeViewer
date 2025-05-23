//
//  AttachViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/11/28.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<NSRunningApplication>
        let cancel: Signal<Void>
    }

    struct Output {}

    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)
        input.attachToProcess.emit(onNext: { [weak self] app in
            guard let self,
                  let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier
            else { return }

            Task {
                do {
                    try await RuntimeInjectClient.shared.installServerFrameworkIfNeeded()
                    guard let dylibURL = Bundle(url: RuntimeInjectClient.shared.serverFrameworkDestinationURL)?.executableURL else { return }
                    try await RuntimeEngineManager.shared.launchAttachedRuntimeEngine(name: name, identifier: bundleIdentifier)
                    try await RuntimeInjectClient.shared.injectApplication(pid: app.processIdentifier, dylibURL: dylibURL)
                } catch {
                    print(error, error.localizedDescription)
                }

                await MainActor.run {
                    self.router.trigger(.dismiss)
                }
            }
        }).disposed(by: rx.disposeBag)
        return Output()
    }
}

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
