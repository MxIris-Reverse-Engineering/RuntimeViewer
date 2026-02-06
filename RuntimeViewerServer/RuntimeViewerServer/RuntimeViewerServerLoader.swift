import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication

#if os(macOS) || targetEnvironment(macCatalyst)
import LaunchServicesPrivate
#elseif canImport(UIKit)
#if os(watchOS)
import WatchKit.WKInterfaceDevice
#else
import UIKit.UIDevice
#endif
#else
#error("Unsupported Platform")
#endif

@_cdecl("swift_initializeRuntimeViewerServer")
func initializeRuntimeViewerServer() {
    RuntimeViewerServerLoader.main()
}

@Loggable
private enum RuntimeViewerServerLoader {
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
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            return bundleID
        }

        let processName = ProcessInfo.processInfo.processName
        let sanitizedName = processName.components(separatedBy: .whitespacesAndNewlines).joined()

        return "com.RuntimeViewer.UnknownBinary.\(sanitizedName)"
    }

    fileprivate static func main() {
        #log(.default, "Attach successfully")
        Task {
            do {
                #log(.default, "Will Launch")

                #if os(macOS) || targetEnvironment(macCatalyst)

                if LSBundleProxy.forCurrentProcess().isSandboxed {
                    runtimeEngine = try await RuntimeEngine(source: .localSocketServer(name: processName, identifier: .init(rawValue: identifier)))
                } else {
                    runtimeEngine = try await RuntimeEngine(source: .remote(name: processName, identifier: .init(rawValue: identifier), role: .server))
                }

                #else

                #if os(watchOS)
                let name = WKInterfaceDevice.current().name
                #else
                let name = await UIDevice.current.name
                #endif

                runtimeEngine = try await RuntimeEngine(source: .bonjourServer(name: name, identifier: .init(rawValue: name)))

                #endif

                #log(.default, "Did Launch")
            } catch {
                #log(.error, "Failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
extension LSBundleProxy {
    fileprivate var isSandboxed: Bool {
        guard let entitlements = entitlements else { return false }
        guard let isSandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool else { return false }
        return isSandboxed
    }
}
#endif
