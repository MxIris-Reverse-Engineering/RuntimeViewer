import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUtilities
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
            let processIdentifier = runningItem.processIdentifier

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
                    let payloadPlatform = try runtimeInjectClient.payloadPlatform(forTargetProcess: processIdentifier)
                    try await runtimeInjectClient.installServerFrameworkIfNeeded(for: payloadPlatform)
                    // Every other failure in this block throws and surfaces as
                    // an alert. A bare `return` here would leave the sheet open
                    // with nothing reported at all — the user clicks Attach and
                    // watches nothing happen.
                    guard let dylibURL = runtimeInjectClient.serverFrameworkExecutableURL(for: payloadPlatform) else {
                        throw RuntimeInjectClient.Error.serverFrameworkNotFound(payloadPlatform)
                    }

                    switch payloadPlatform {
                    case .iOSSimulator:
                        try await attachToSimulatorProcess(name: name, processIdentifier: processIdentifier, dylibURL: dylibURL)
                    case .macOS:
                        try await attachToLocalProcess(name: name, processIdentifier: processIdentifier, dylibURL: dylibURL)
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

    /// The Mac flow: bring up a client engine, inject, confirm the payload
    /// connected back to it.
    @MainActor
    private func attachToLocalProcess(name: String, processIdentifier: pid_t, dylibURL: URL) async throws {
        let identifier = processIdentifier.description
        // Probe the target's live sandbox rather than reading RunningApplicationKit's
        // entitlement-only `isSandboxed`, which misses seatbelt-profiled daemons
        // (e.g. rapportd) that deny mach-lookup yet carry no app-sandbox entitlement.
        let isSandbox = SandboxProbe.isRuntimeViewerServiceMachLookupBlocked(pid: processIdentifier)

        try await runtimeEngineManager.launchAttachedRuntimeEngine(name: name, identifier: identifier, isSandbox: isSandbox)
        do {
            try await inject(processIdentifier: processIdentifier, dylibURL: dylibURL)
            // `connect()` only brought up the local half and optimistically reported
            // `.connected`; confirm the injected peer actually connected back before
            // dismissing, so a rejected connection surfaces an error and the engine is
            // torn down instead of lingering silently.
            try await runtimeEngineManager.confirmAttachedRuntimeEngineConnected(name: name, identifier: identifier, isSandbox: isSandbox)
        } catch {
            runtimeEngineManager.terminateAttachedRuntimeEngine(name: name, identifier: identifier, isSandbox: isSandbox)
            throw error
        }
    }

    /// The simulator flow: inject, then wait for the payload to advertise itself.
    ///
    /// No engine is launched first, and none has to be torn down on failure. A
    /// simulator payload picks its transport at compile time and always
    /// advertises over Bonjour (see `RuntimeViewerServer.main()`), so the
    /// browser already running in this process is what connects to it — the
    /// XPC/socket endpoint the Mac flow prepares would never be dialled.
    ///
    /// The sandbox probe is skipped for the same reason: it exists to choose
    /// between the XPC and localhost-socket transports, and neither is in play.
    @MainActor
    private func attachToSimulatorProcess(name: String, processIdentifier: pid_t, dylibURL: URL) async throws {
        // Which simulator the target belongs to, read before injecting so a
        // failure here costs nothing. The pid alone cannot identify the
        // payload's advertisement — pids are per device, and the endpoint key
        // the payload lands under is `{deviceID}-{pid}`.
        guard let deviceID = ProcessEnvironmentProbe.environment(ofProcess: processIdentifier)?["SIMULATOR_UDID"],
              !deviceID.isEmpty
        else {
            throw RuntimeEngineManager.AttachedEngineHandshakeError.simulatorDeviceUnidentifiable(
                name: name,
                processIdentifier: processIdentifier
            )
        }

        try await inject(processIdentifier: processIdentifier, dylibURL: dylibURL)
        try await runtimeEngineManager.awaitInjectedBonjourEngine(
            name: name,
            deviceID: deviceID,
            processIdentifier: processIdentifier
        )
    }

    /// dlopen or mach_vm_remap is the daemon's call — it probes the target's
    /// sandbox and code signing to find out which one the target will accept.
    /// All we owe it is the entry symbol the remap path needs.
    @MainActor
    private func inject(processIdentifier: pid_t, dylibURL: URL) async throws {
        try await runtimeInjectClient.injectApplication(
            pid: processIdentifier,
            dylibURL: dylibURL,
            remapEntrySymbol: "runtime_viewer_server_start"
        )
    }
}
