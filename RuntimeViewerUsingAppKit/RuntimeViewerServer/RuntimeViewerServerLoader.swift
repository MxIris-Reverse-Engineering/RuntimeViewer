import AppKit
internal import os.log
internal import RuntimeViewerCore
import LaunchServicesPrivate

@objc
public final class RuntimeViewerServerLoader: NSObject {
    private static var runtimeEngine: RuntimeEngine?

    private static let logger = Logger(subsystem: "com.RuntimeViewer.RuntimeViewerServer", category: "RuntimeViewerServerLoader")
    
    @objc public static func main() {
        logger.info("Attach successfully")
        
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? Bundle.main.name
        
        Task {
            do {
                logger.info("Will Launch")
                if LSBundleProxy.forCurrentProcess().isSandboxed {
                    runtimeEngine = try await RuntimeEngine(source: .localSocketServer(name: name, identifier: .init(rawValue: Bundle.main.bundleIdentifier!)))
                } else {
                    runtimeEngine = try await RuntimeEngine(source: .remote(name: name, identifier: .init(rawValue: Bundle.main.bundleIdentifier!), role: .server))
                }
                logger.info("Did Launch")
            } catch {
                logger.error("Failed to create runtime engine: \(error, privacy: .public)")
            }
        }
    }
}

extension LSBundleProxy {
    var isSandboxed: Bool {
        guard let entitlements = entitlements else { return false }
        guard let isSandboxed = entitlements["com.apple.security.app-sandbox"] as? Bool else { return false }
        return isSandboxed
    }
}
