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

    @Dependency(\.runtimeEngineIconProvider)
    private var runtimeEngineIconProvider

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
                        // The row's icon travels with the target. It is the one
                        // thing about a process on a device that this side
                        // cannot work out later: it came from a file in a bundle
                        // on that device, fetched to draw this very row.
                        try await attachToRemoteProcess(target, icon: runningItem.icon, using: runtimeEngine)
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
    /// The payload is not staged or launched here — the device carries it. What this side
    /// does is get ready to be reached: it opens a listener and tells the device where it
    /// is, because on a real device the payload runs inside a process whose sandbox denies
    /// `network-bind` and so cannot be listened *for*.
    ///
    /// It then waits for either arrangement. A simulator payload, and a device app built
    /// before the rendezvous existed, still advertise themselves instead; the wait races
    /// both and drops the half nobody used. See
    /// `Documentations/Evolutions/draft-device-payload-reverse-connection.md`.
    ///
    /// - Parameter icon: What the picker showed for this process — the application's own
    ///   icon, or the generic executable icon for a daemon. Recorded against the engine
    ///   that reports in, because nothing downstream could derive it: the engine list
    ///   resolves an icon from `NSRunningApplication`, which knows only this Mac's
    ///   processes, and would otherwise fall back to the icon of the *device* and label
    ///   every injected process with a picture of the phone.
    @discardableResult
    private func attachToRemoteProcess(
        _ target: RuntimeProcessAttacher.Target,
        icon: NSImage?,
        using runtimeEngine: RuntimeEngine,
    ) async throws -> RuntimeEngine {
        // Still needed, and only for the advertising half of the race: an advertisement is
        // matched on `{deviceID}-{pid}`. It is read off the engine's bookmark scope, the one
        // place that carries it as an honest optional — `hostInfo.hostID` falls back to an
        // instance identifier or a display name when the peer publishes no device key, and
        // matching on either of those would pair this request with the wrong process.
        guard case .identified(.bonjour(let deviceIdentifier, _, _)) = runtimeEngine.bookmarkScope else {
            throw AttachFailure.deviceHasNoIdentifier(engineName: runtimeEngine.source.description)
        }

        // Built from the connection to this device, so the address is one that device
        // demonstrably reaches this Mac on rather than a guess among its interfaces.
        let rendezvous = try await RuntimePayloadRendezvous.reachingThisProcess(from: runtimeEngine)
        // Listening first: the payload dials as it starts up, and a listener brought up
        // afterwards would cost the user a retry interval of watching nothing happen.
        //
        // The device's identity goes with it. Without that the engine inherits this
        // machine's, and the engine list — which groups by host — files a process that
        // lives on a phone under the Mac, next to the Mac's own.
        // The device engine and the pid go with it so the teardown can tell the
        // device to let that process be suspended again: on a device the
        // injection has to hold a RunningBoard assertion on the target for as
        // long as the engine lasts, and `.injectedTCP` carries the rendezvous
        // rather than the pid.
        try await runtimeEngineManager.launchInjectedDeviceEngine(
            name: target.name,
            rendezvous: rendezvous,
            deviceHostInfo: runtimeEngine.hostInfo,
            deviceIdentifier: deviceIdentifier,
            deviceEngine: runtimeEngine,
            processIdentifier: target.processIdentifier,
        )

        do {
            let result = try await runtimeEngine.inject(
                intoProcessWithIdentifier: target.processIdentifier,
                rendezvous: rendezvous,
            )
            guard result.isInjected else {
                throw AttachFailure.injectionRefused(result)
            }

            // Either half of the race can win, so the icon is filed against the engine
            // that actually reported in rather than the one the listener created.
            let injectedEngine = try await runtimeEngineManager.awaitInjectedDeviceEngine(
                name: target.name,
                rendezvous: rendezvous,
                deviceID: deviceIdentifier,
                processIdentifier: target.processIdentifier,
            )
            if let icon {
                runtimeEngineIconProvider.record(icon, for: injectedEngine)
            }
            return injectedEngine
        } catch {
            // Every failure from here on leaves a listener nobody will ever dial. Left in
            // place it would hold its port and show up in the engine list as a process that
            // is not there.
            runtimeEngineManager.terminateInjectedDeviceEngine(name: target.name, rendezvous: rendezvous)
            throw error
        }
    }
}
