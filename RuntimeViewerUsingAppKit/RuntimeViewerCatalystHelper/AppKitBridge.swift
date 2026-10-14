import Foundation

/// Loads `RuntimeViewerCatalystHelperPlugin`, the macOS code that does the
/// work in both Mac Catalyst shells: the helper application and the XPC
/// service. Compiled into both.
@objcMembers
final class AppKitBridge: NSObject {
    static let shared = AppKitBridge()

    private(set) var plugin: AppKitPlugin?

    enum Error: Swift.Error {
        case failedLoadBundleFile
        case failedLoadPrincipalClass
    }

    /// The one copy of the plugin the app ships, in its `Contents/PlugIns`.
    /// Both shells sit two levels below `Contents` — the helper application
    /// in `Contents/Applications`, the XPC service in `Contents/XPCServices`.
    static var pluginBundleURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PlugIns/RuntimeViewerCatalystHelperPlugin.bundle")
    }

    @discardableResult
    func loadPlugins() throws -> AppKitPlugin {
        guard let bundle = Bundle(url: Self.pluginBundleURL) else {
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
