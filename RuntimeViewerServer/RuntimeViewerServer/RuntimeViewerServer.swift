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

                // Several processes on one device can each carry a payload —
                // injecting a simulator is the case that made this necessary —
                // so the host must be able to tell them apart. It does that
                // from the TXT record (device ID plus pid), not from this name,
                // which stays readable and launch-stable for hosts that predate
                // those keys.
                let serviceName = await RuntimeNetworkBonjour.resolvedServiceName()

                runtimeEngine = RuntimeEngine(source: .bonjour(name: serviceName, identifier: .init(rawValue: serviceName), role: .server))
                try await runtimeEngine?.connect()

                #endif

                #log(.default, "RuntimeViewerServer Did Launch")
            } catch {
                #log(.error, "RuntimeViewerServer failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }
}
