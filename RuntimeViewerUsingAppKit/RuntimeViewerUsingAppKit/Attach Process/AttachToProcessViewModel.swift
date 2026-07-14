import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient

@Loggable(.private)
final class AttachToProcessViewModel: ViewModel<MainRoute> {
    struct Input {
        let attachToProcess: Signal<any RunningItem>
        let cancel: Signal<Void>
    }

    struct Output {}

    enum Error: LocalizedError {
        case sandboxAppNoSupported

        var errorDescription: String? {
            "Sandbox apps are not currently supported"
        }
    }

    @Dependency(\.runtimeInjectClient)
    private var runtimeInjectClient
    
    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    @Observed private(set) var isAttaching: Bool = false

    override var delayedLoading: Driver<Bool> {
        $isAttaching.asDriver()
    }

    func transform(_ input: Input) -> Output {
        input.cancel.emit(to: router.rx.trigger(.dismiss)).disposed(by: rx.disposeBag)
        input.attachToProcess.emitOnNext { [weak self] runningItem in
            guard let self else { return }

            let name = runningItem.name
            let identifier = runningItem.processIdentifier.description
            // Probe the target's live sandbox rather than reading RunningApplicationKit's
            // entitlement-only `isSandboxed`, which misses seatbelt-profiled daemons
            // (e.g. rapportd) that deny mach-lookup yet carry no app-sandbox entitlement.
            let isSandbox = SandboxProbe.isRuntimeViewerServiceMachLookupBlocked(pid: runningItem.processIdentifier)

            Task { @MainActor [weak self] in
                guard let self else { return }
                isAttaching = true
                defer { isAttaching = false }
                do {
                    try await runtimeInjectClient.installServerFrameworkIfNeeded()
                    guard let dylibURL = Bundle(url: runtimeInjectClient.serverFrameworkDestinationURL)?.executableURL else { return }

                    try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: identifier, isSandbox: isSandbox)
                    try await runtimeInjectClient.injectApplication(pid: runningItem.processIdentifier, dylibURL: dylibURL)
                    // `connect()` only brought up the local half and optimistically reported
                    // `.connected`; confirm the injected peer actually connected back before
                    // dismissing, so a rejected connection surfaces an error and the engine is
                    // torn down instead of lingering silently.
                    try await runtimeEngineManager.confirmAttachedRuntimeEngineConnected(name: name, identifier: identifier, isSandbox: isSandbox)

                    router.trigger(.dismiss)
                } catch {
                    runtimeEngineManager.terminateAttachedRuntimeEngine(name: name, identifier: identifier, isSandbox: isSandbox)
                    #log(.error, "\(error, privacy: .public)")
                    errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        return Output()
    }
}
