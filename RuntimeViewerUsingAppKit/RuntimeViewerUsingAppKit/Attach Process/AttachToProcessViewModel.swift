import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerEngineManagement

/// Collects the target the user picked and gets a payload into it.
///
/// Two paths, because the work happens in different places. A process on this Mac is
/// injected by this Mac: the flow — payload selection, install, injection, handshake —
/// lives in `RuntimeProcessAttacher` so processes without a window can run it too. A
/// process on a device is injected *by that device*, so all this side does is ask and then
/// wait for the payload to advertise itself.
///
/// This ViewModel owns only what the sheet needs: the loading state, the dismissal, and
/// the error alert.
@Loggable(.private)
final class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<any RunningItem>
        /// A device that could not produce its process list. Raised here rather than left
        /// as an empty picker, which says nothing about why it is empty.
        let processListFailed: Signal<any Error>
        let cancel: Signal<Void>
    }

    struct Output {}

    /// Why an attach could not even be started, in words meant to be read as-is.
    private enum AttachFailure: LocalizedError {
        case deviceHasNoIdentifier(engineName: String)
        case injectionRefused(RuntimeProcessInjectionResult)

        var errorDescription: String? {
            switch self {
            case .deviceHasNoIdentifier(let engineName):
                // The injected payload is matched back to this request by device
                // identifier plus pid, so without the identifier there is no way to tell
                // which of the advertisements that follow is the one we caused.
                return "\(engineName) does not publish a device identifier, so Runtime Viewer cannot tell which injected process is the one it asked for."
            case .injectionRefused(let result):
                switch result {
                case .injected:
                    // Not reachable: this case is only built for a result that is not
                    // `.injected`. Stated rather than force-unwrapped away.
                    return "The injection succeeded."
                case .taskPortUnavailable(let reason):
                    return "That device would not give Runtime Viewer control of the process: \(reason)"
                case .targetRefusedPayload(let reason):
                    return "The process refused to load the Runtime Viewer payload: \(reason)"
                case .failed(_, let reason):
                    return reason
                }
            }
        }
    }

    @Dependency(\.runtimeInjectClient)
    private var runtimeInjectClient

    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    @RxObserved private(set) var isAttaching: Bool = false

    override var delayedLoading: Driver<Bool> {
        $isAttaching.asDriver()
    }

    /// The engine whose process list the sheet is showing.
    ///
    /// Held rather than re-read from `documentState` when the user confirms. The two can
    /// diverge — a peer disconnecting and being replaced switches the document's engine
    /// while this sheet is open — and the pid the user picked only means anything on the
    /// machine it was listed from. Re-reading would inject into whatever engine happens to
    /// be selected by then, using an identifier from a different machine's process table.
    private let attachmentEngine: RuntimeEngine

    init(attachmentEngine: RuntimeEngine, documentState: DocumentState, router: any Router<MainRoute>) {
        self.attachmentEngine = attachmentEngine
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)

        input.processListFailed.emitOnNext { [weak self] error in
            guard let self else { return }
            #log(.error, "\(error, privacy: .public)")
            errorRelay.accept(error)
        }
        .disposed(by: rx.disposeBag)

        input.attachToProcess.emitOnNext { [weak self] runningItem in
            guard let self else { return }

            let runtimeEngine = attachmentEngine
            let target = RuntimeProcessAttacher.Target(name: runningItem.name, processIdentifier: runningItem.processIdentifier)

            Task { @MainActor [weak self] in
                guard let self else { return }
                isAttaching = true
                defer { isAttaching = false }
                do {
                    if runtimeEngine.injectionTargetsRunOnThisMachine {
                        let attacher = RuntimeProcessAttacher(engineManager: runtimeEngineManager, injectClient: runtimeInjectClient)
                        _ = try await attacher.attach(target)
                    } else {
                        try await attachToRemoteProcess(target, using: runtimeEngine)
                    }
                    router.trigger(.dismiss)
                } catch {
                    #log(.error, "\(error, privacy: .public)")
                    errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        return Output()
    }

    /// Asks the device to inject its own payload, then waits for the result to show up as
    /// an engine.
    ///
    /// Nothing is staged or launched on this side: the device carries the payload and
    /// advertises the injected process over Bonjour, which the browser already running
    /// here picks up. That is the same arrangement the iOS Simulator path uses — which is
    /// why `awaitInjectedBonjourEngine` is reused rather than reinvented.
    @discardableResult
    private func attachToRemoteProcess(
        _ target: RuntimeProcessAttacher.Target,
        using runtimeEngine: RuntimeEngine,
    ) async throws -> RuntimeEngine {
        // The advertisement is matched on `{deviceID}-{pid}`, so the device identifier has
        // to be known before injecting. It is read off the engine's bookmark scope, the one
        // place that carries it as an honest optional — `hostInfo.hostID` falls back to an
        // instance identifier or a display name when the peer publishes no device key, and
        // matching on either of those would pair this request with the wrong process.
        guard case .identified(.bonjour(let deviceIdentifier, _, _)) = runtimeEngine.bookmarkScope else {
            throw AttachFailure.deviceHasNoIdentifier(engineName: runtimeEngine.source.description)
        }

        let result = try await runtimeEngine.inject(intoProcessWithIdentifier: target.processIdentifier)
        guard result.isInjected else {
            throw AttachFailure.injectionRefused(result)
        }

        return try await runtimeEngineManager.awaitInjectedBonjourEngine(
            name: target.name,
            deviceID: deviceIdentifier,
            processIdentifier: target.processIdentifier,
        )
    }
}
