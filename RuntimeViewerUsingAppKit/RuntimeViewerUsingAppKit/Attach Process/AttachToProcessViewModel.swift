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
                    // Which slice the target can load. A macOS process and an
                    // iOS Simulator process on this Mac share a cputype and are
                    // told apart only by their LC_BUILD_VERSION, so this has to
                    // be read rather than assumed — and it throws for a target
                    // we ship no payload for, instead of handing over the
                    // nearest slice and letting dyld refuse it.
                    let payloadPlatform = try runtimeInjectClient.payloadPlatform(
                        forTargetProcess: runningItem.processIdentifier
                    )
                    try await runtimeInjectClient.installServerFrameworkIfNeeded(for: payloadPlatform)
                    guard let dylibURL = runtimeInjectClient.serverFrameworkExecutableURL(for: payloadPlatform) else { return }

                    try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: identifier, isSandbox: isSandbox)

                    // dlopen or mach_vm_remap is the daemon's call — it probes the target's
                    // sandbox and code signing to find out which one the target will accept.
                    // All we owe it is the entry symbol the remap path needs.
                    try await runtimeInjectClient.injectApplication(
                        pid: runningItem.processIdentifier,
                        dylibURL: dylibURL,
                        remapEntrySymbol: "runtime_viewer_server_start"
                    )
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
