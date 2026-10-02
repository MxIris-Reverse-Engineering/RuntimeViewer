import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUtilities

#if canImport(UIKit)
#if os(watchOS)
import WatchKit.WKInterfaceDevice
#else
import UIKit.UIDevice
#endif
#elseif !os(macOS) && !targetEnvironment(macCatalyst)
#error("Unsupported Platform")
#endif

@_cdecl("swift_initializeRuntimeViewerServer")
func initializeRuntimeViewerServer() {
    RuntimeViewerServer.main()
}

@Loggable(.private)
private enum RuntimeViewerServer {
    private static var runtimeEngine: RuntimeEngine?

    /// The advertised display name.
    ///
    /// Deliberately `RuntimeNetworkBonjour`'s copy rather than a private one.
    /// This used to be duplicated here without its `isEmpty` checks, so a target
    /// declaring an empty `CFBundleDisplayName` — three apps on a typical Mac do
    /// — named the XPC and localSocket sources the empty string while the
    /// Bonjour branch, going through the shared copy, named them correctly.
    private static var processName: String { RuntimeNetworkBonjour.localProcessName }

    private static var identifier: String {
        return ProcessInfo.processInfo.processIdentifier.description
    }

    fileprivate static func main() {
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif
        // Every entry point into this type is an injection, so declare it
        // before any identity is derived: the payload runs inside a process it
        // does not own and must not persist anything into that process.
        RuntimeNetworkBonjour.isRunningInsideInjectedProcess = true
        #log(.default, "Attach successfully")
        Task {
            do {
                #log(.default, "RuntimeViewerServer Will Launch")

                #if os(macOS) || targetEnvironment(macCatalyst)

                // A sandbox that denies mach-lookup of our helper service (App
                // Sandbox apps and seatbelt-profiled daemons like rapportd) makes
                // the XPC path impossible; fall back to the localhost socket, which
                // only needs an outbound connect().
                if SandboxProbe.isMachLookupBlocked(
                    pid: ProcessInfo.processInfo.processIdentifier,
                    globalName: RuntimeViewerMachServiceName
                ) {
                    runtimeEngine = RuntimeEngine(source: .localSocket(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()
                } else {
                    runtimeEngine = RuntimeEngine(source: .remote(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()
                }

                #else

                runtimeEngine = RuntimeEngine(source: await iOSSource())
                try await runtimeEngine?.connect()

                #endif

                #log(.default, "RuntimeViewerServer Did Launch")
            } catch {
                #log(.error, "RuntimeViewerServer failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }

    #if !os(macOS) && !targetEnvironment(macCatalyst)

    /// Which way this payload talks to the host.
    ///
    /// Two shapes, and the device needs the second one for a reason nothing in
    /// this process can detect: the payload inherits the *target's* sandbox, and
    /// the kernel denies `network-bind` to most iOS daemons — measured, four of
    /// seven targets on one device. An advertising payload in one of those never
    /// gets a listener up, so there is nothing for the host to find and no error
    /// anywhere the user can see it.
    ///
    /// Background: `Documentations/Evolutions/draft-device-payload-reverse-connection.md`.
    private static func iOSSource() async -> RuntimeSource {
        #if targetEnvironment(simulator)

        // The simulator advertises itself, and that path is verified: its guest
        // sandbox does not deny `bind`, and `SIMULATOR_UDID` gives the identity
        // derivation something reliable to answer with. Nothing here to fix.
        return await advertisingSource()

        #else

        guard let rendezvous = RuntimePayloadRendezvous.stagedBesideImage(#dsohandle) else {
            // An injector that staged none predates this, so it is waiting to
            // find an advertisement. Doing anything else would break it.
            #log(.default, "No rendezvous was staged beside this payload; advertising instead")
            return await advertisingSource()
        }

        #log(
            .default,
            "Reporting to the host that injected this payload at \(rendezvous.hostAddress, privacy: .public):\(rendezvous.hostPort, privacy: .public)"
        )
        return .injectedTCP(
            name: processName,
            host: rendezvous.hostAddress,
            port: rendezvous.hostPort,
            // The claim token, presented as-is. This is the whole of what the
            // host matches on, which is what keeps the payload out of the
            // business of working out which device it is on — measured to be
            // unanswerable from inside some targets.
            identifier: .init(rawValue: rendezvous.claimToken),
            // Business server, socket client: it answers queries, and it dialled.
            role: .server,
        )

        #endif
    }

    /// Several processes on one device can each carry a payload — injecting a
    /// simulator is the case that made this necessary — so the host must be able
    /// to tell them apart. It does that from the TXT record (device ID plus pid),
    /// not from this name, which stays readable and launch-stable for hosts that
    /// predate those keys.
    private static func advertisingSource() async -> RuntimeSource {
        let serviceName = await RuntimeNetworkBonjour.resolvedServiceName()
        return .bonjour(name: serviceName, identifier: .init(rawValue: serviceName), role: .server)
    }

    #endif
}
