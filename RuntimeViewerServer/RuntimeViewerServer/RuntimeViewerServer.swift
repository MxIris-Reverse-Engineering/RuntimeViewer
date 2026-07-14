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

    private static var processName: String {
        if let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String {
            return displayName
        }

        if let bundleName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String {
            return bundleName
        }

        return ProcessInfo.processInfo.processName
    }

    private static var identifier: String {
        return ProcessInfo.processInfo.processIdentifier.description
    }

    fileprivate static func main() {
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif
        #log(.default, "Attach successfully")
        Task {
            do {
                #log(.default, "RuntimeViewerServer Will Launch")

                #if os(macOS) || targetEnvironment(macCatalyst)

                // A sandbox that denies mach-lookup of our helper service (App
                // Sandbox apps and seatbelt-profiled daemons like rapportd) makes
                // the XPC path impossible; fall back to the localhost socket, which
                // only needs an outbound connect().
                if SandboxProbe.isRuntimeViewerServiceMachLookupBlocked(pid: ProcessInfo.processInfo.processIdentifier) {
                    runtimeEngine = RuntimeEngine(source: .localSocket(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()
                } else {
                    runtimeEngine = RuntimeEngine(source: .remote(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()
                }

                #else

                let name = RuntimeNetworkBonjour.localHostName
                let deviceID = DeviceIdentifier.uniqueDeviceID

                runtimeEngine = RuntimeEngine(source: .bonjour(name: name, identifier: .init(rawValue: deviceID), role: .server))
                try await runtimeEngine?.connect()

                #endif

                #log(.default, "RuntimeViewerServer Did Launch")
            } catch {
                #log(.error, "RuntimeViewerServer failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }
}
