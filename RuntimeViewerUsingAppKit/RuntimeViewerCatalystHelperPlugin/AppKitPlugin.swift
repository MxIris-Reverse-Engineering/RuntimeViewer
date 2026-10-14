import Foundation

/// The plugin's face to the two Mac Catalyst shells that load it. Each shell
/// only makes its process a Catalyst one, then calls one of these.
@objc(AppKitPlugin)
protocol AppKitPlugin: NSObjectProtocol {
    init()

    /// The helper application: serve the Catalyst runtime to whoever reaches
    /// it through the helper daemon — the standalone `runtime-viewer-cli`
    /// host.
    func launch()

    /// The XPC service the app embeds: serve the Catalyst runtime on the
    /// service's listener. Never returns; the main thread ends up in
    /// `xpc_main`.
    func runService()
}
