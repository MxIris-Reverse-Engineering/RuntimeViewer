import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerUtilities

#if os(macOS) || targetEnvironment(macCatalyst)
import LaunchServicesPrivate
#endif

#if os(macOS)
import SwiftyXPC
#endif

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
        #log(.default, "Attach successfully")
        Task {
            do {
                #log(.default, "Will Launch")

                #if os(macOS) || targetEnvironment(macCatalyst)

                if let proxy = LSBundleProxy.forCurrentProcess(), proxy.isSandbox {
                    runtimeEngine = RuntimeEngine(source: .localSocket(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()
                } else {
                    runtimeEngine = RuntimeEngine(source: .remote(name: processName, identifier: .init(rawValue: identifier), role: .server))
                    try await runtimeEngine?.connect()

                    // Register the XPC listener endpoint with the Mach Service
                    // so the Host can reconnect after restart.
                    #if os(macOS)
                    await registerInjectedEndpoint()
                    #endif
                }

                #else

                let name = RuntimeNetworkBonjour.localHostName
                let deviceID = DeviceIdentifier.uniqueDeviceID

                runtimeEngine = RuntimeEngine(source: .bonjour(name: name, identifier: .init(rawValue: deviceID), role: .server))
                try await runtimeEngine?.connect()

                #endif

                #log(.default, "Did Launch")
            } catch {
                #log(.error, "Failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }

    #if os(macOS)
    private static func registerInjectedEndpoint() async {
        guard let endpoint = await runtimeEngine?.xpcListenerEndpoint as? SwiftyXPC.XPCEndpoint else {
            #log(.error, "Failed to get XPC listener endpoint for registration")
            return
        }

        do {
            let connection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
            connection.activate()
            try await connection.sendMessage(request: RegisterInjectedEndpointRequest(
                pid: ProcessInfo.processInfo.processIdentifier,
                appName: processName,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                endpoint: endpoint
            ))
            #log(.info, "Registered injected endpoint with Mach Service (PID: \(ProcessInfo.processInfo.processIdentifier))")
        } catch {
            #log(.error, "Failed to register injected endpoint: \(error, privacy: .public)")
        }
    }
    #endif
}
