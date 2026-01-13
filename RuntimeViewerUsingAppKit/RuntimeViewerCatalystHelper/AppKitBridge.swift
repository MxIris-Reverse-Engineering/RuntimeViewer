import Foundation

@objcMembers
final class AppKitBridge: NSObject {
    static let shared = AppKitBridge()
    
    private(set) var plugin: AppKitPlugin?

    enum Error: Swift.Error {
        case failedCreateBundlePath
        case failedLoadBundleFile
        case failedLoadPrincipalClass
    }

    @discardableResult
    func loadPlugins() throws -> AppKitPlugin {
        guard let bundlePath = Bundle.main.builtInPlugInsURL?.appendingPathComponent("RuntimeViewerCatalystHelperPlugin.bundle").path else {
            throw Error.failedCreateBundlePath
        }

        guard let bundle = Bundle(path: bundlePath) else {
            throw Error.failedLoadBundleFile
        }
        
        guard let principalClass = bundle.principalClass as? AppKitPlugin.Type else {
            throw Error.failedLoadPrincipalClass
        }

        let plugin = principalClass.init()
        self.plugin = plugin
        return plugin
    }
}
