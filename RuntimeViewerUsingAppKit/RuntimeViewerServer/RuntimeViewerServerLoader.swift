import AppKit
internal import Logging
internal import RuntimeViewerCore
import LaunchServicesPrivate

@objc
public final class RuntimeViewerServerLoader: NSObject {
    private static var runtimeEngine: RuntimeEngine?

    private static let logger = Logger(label: "RumtimeViewerServer")
    
    @objc public static func main() {
        logger.info("Attach successfully")
        
        let name = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? Bundle.main.name
        
        Task {
            do {
                if LSBundleProxy.forCurrentProcess().isSandboxed {
                    runtimeEngine = try await RuntimeEngine(source: .bonjourServer(name: name, identifier: .init(rawValue: name)))
                } else {
                    runtimeEngine = try await RuntimeEngine(source: .remote(name: name, identifier: .init(rawValue: Bundle.main.bundleIdentifier!), role: .server))
                }
            } catch {
                logger.error("Failed to create runtime engine: \(error)")
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
