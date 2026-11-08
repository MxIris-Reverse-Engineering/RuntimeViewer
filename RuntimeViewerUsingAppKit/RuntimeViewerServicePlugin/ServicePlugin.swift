import Foundation

/// The plugin's face to the four shells that load it. Each shell only makes
/// its process what it has to be — a Mac Catalyst application, a Mac Catalyst
/// XPC service, a macOS XPC service — then calls one of these. Compiled into
/// the plugin and into every shell.
@objc(ServicePlugin)
protocol ServicePlugin: NSObjectProtocol {
    init()

    /// The Mac Catalyst helper application: serve the Catalyst runtime to
    /// whoever reaches it through the helper daemon — the standalone
    /// `runtime-viewer-cli` host.
    func launchCatalystHelper()

    /// The Mac Catalyst XPC service the app embeds: serve "My Mac (Mac
    /// Catalyst)" on the service's listener. Never returns; the main thread
    /// ends up in `xpc_main`.
    func runCatalystService()

    /// The local XPC service the app embeds: serve "My Mac" on the service's
    /// listener. Never returns; the main thread ends up in `xpc_main`.
    func runLocalService()

    /// The offline XPC service the app embeds, one instance per file: serve
    /// the file the connection's first hello names. Never returns; the main
    /// thread ends up in `xpc_main`.
    func runOfflineService()
}
