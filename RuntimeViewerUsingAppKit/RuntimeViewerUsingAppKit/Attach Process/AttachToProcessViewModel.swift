import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerEngineManagement

/// Collects the target the user picked and hands it to `RuntimeProcessAttacher`.
///
/// The attach flow itself — payload selection, install, injection, handshake —
/// lives in `RuntimeProcessAttacher` so processes without a window can run it
/// too. This ViewModel only owns what the sheet needs: the loading state, the
/// dismissal, and the error alert.
@Loggable(.private)
final class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<any RunningItem>
        let cancel: Signal<Void>
    }

    struct Output {}

    @Dependency(\.runtimeInjectClient)
    private var runtimeInjectClient

    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    @RxObserved private(set) var isAttaching: Bool = false

    override var delayedLoading: Driver<Bool> {
        $isAttaching.asDriver()
    }

    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)
        input.attachToProcess.emitOnNext { [weak self] runningItem in
            guard let self else { return }

            let target = RuntimeProcessAttacher.Target(name: runningItem.name, processIdentifier: runningItem.processIdentifier)

            Task { @MainActor [weak self] in
                guard let self else { return }
                isAttaching = true
                defer { isAttaching = false }
                do {
                    let attacher = RuntimeProcessAttacher(engineManager: runtimeEngineManager, injectClient: runtimeInjectClient)
                    _ = try await attacher.attach(target)
                    router.trigger(.dismiss)
                } catch {
                    #log(.error, "\(error, privacy: .public)")
                    errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        return Output()
    }
}
