import Foundation

/// Loads `RuntimeViewerServicePlugin`, the macOS code that does the work in
/// the four shells: the Mac Catalyst helper application and the Mac Catalyst,
/// local and offline XPC services. Compiled into every shell, not into the
/// plugin.
///
/// The plugin instance keeps its engine and its host, so whoever calls an
/// entry point that returns — only `launchCatalystHelper()` does — has to keep
/// the instance alive.
enum ServicePluginLoader {
    enum Error: Swift.Error {
        case failedLoadBundleFile
        case failedLoadPrincipalClass
    }

    /// The one copy of the plugin the app ships, in its `Contents/PlugIns`.
    /// Every shell sits two levels below `Contents` — the helper application
    /// in `Contents/Applications`, the XPC services in `Contents/XPCServices`.
    static var pluginBundleURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PlugIns/RuntimeViewerServicePlugin.bundle")
    }

    static func loadPlugin() throws -> ServicePlugin {
        guard let bundle = Bundle(url: pluginBundleURL) else {
            throw Error.failedLoadBundleFile
        }

        guard let principalClass = bundle.principalClass as? ServicePlugin.Type else {
            throw Error.failedLoadPrincipalClass
        }

        return principalClass.init()
    }
}
