import Foundation
import FoundationToolbox
import RuntimeViewerCommunication

extension RuntimeEngine {
    /// A set of commands another module asked to have installed on every
    /// connection.
    private struct CommandExtension {
        /// Identity for the idempotence check, and what the out-of-order
        /// diagnostic names. Not a wire value.
        let name: String

        let install: @Sendable (RuntimeEngineCommandRegistrar) -> Void
    }

    private static let commandExtensionsLock = NSLock()

    private nonisolated(unsafe) static var registeredCommandExtensions: [CommandExtension] = []

    private nonisolated(unsafe) static var hasInstalledHandlersOnAnyConnection = false

    /// Appends a set of commands declared by another module.
    ///
    /// Every connection established from now on installs them, after the
    /// built-in commands and in the order the extensions were added.
    ///
    /// Idempotent: adding the same `name` again keeps only the first, so an app
    /// and an XPC service it embeds may each call it once safely.
    ///
    /// **Call it before any engine establishes a connection.** Installation
    /// happens at the moment a connection is set up, and there is no
    /// after-the-fact path — retrofitting would either install handlers twice
    /// or make Core keep a table of live connections, both of which cost more
    /// than one call at a process entry point. A call that arrives after the
    /// first installation still takes effect for later connections, and logs an
    /// `.error`, because its symptom (a peer that looks like an old build to
    /// the host) sits too far from its cause to be guessed at.
    public static func addCommandExtension(
        named name: String,
        install: @escaping @Sendable (RuntimeEngineCommandRegistrar) -> Void,
    ) {
        commandExtensionsLock.lock()
        defer { commandExtensionsLock.unlock() }
        guard !registeredCommandExtensions.contains(where: { $0.name == name }) else { return }
        registeredCommandExtensions.append(CommandExtension(name: name, install: install))
        if hasInstalledHandlersOnAnyConnection {
            RuntimeEngineCommandExtensionLog.commandExtensionAddedTooLate(name)
        }
    }

    /// The extensions to install, marking that installation has begun.
    ///
    /// One locked operation rather than a read plus a separate marking call, so
    /// the two cannot interleave with an `addCommandExtension` and report the
    /// wrong verdict about lateness.
    private static func commandExtensionsForInstallation() -> [CommandExtension] {
        commandExtensionsLock.lock()
        defer { commandExtensionsLock.unlock() }
        hasInstalledHandlersOnAnyConnection = true
        return registeredCommandExtensions
    }

    /// Every command that both `setupMessageHandlerForServer` and
    /// `RuntimeEngineProxyServer.setupRequestHandlers` need to expose: the
    /// built-in list, then whatever other modules added.
    ///
    /// Adding a command to Core means one line in
    /// ``registerBuiltInHandlers(into:)``. Adding one from *another* module
    /// means a call to ``addCommandExtension(named:install:)`` and no edit
    /// here at all.
    ///
    /// `inboundRequests` is the connection's registry of withdrawable
    /// requests. An identifier means something only to the peer that minted
    /// it, so a connection's owner passes the one it keeps for that
    /// connection; the default, a registry of this call's own, serves a
    /// connection whose handlers are installed once.
    static func registerSharedHandlers(
        on connection: any RuntimeConnection,
        engine: RuntimeEngine,
        inboundRequests: RuntimeEngineInboundRequests = RuntimeEngineInboundRequests()
    ) {
        let registrar = RuntimeEngineCommandRegistrar(connection: connection, engine: engine, inboundRequests: inboundRequests)
        registerBuiltInHandlers(into: registrar)
        for commandExtension in commandExtensionsForInstallation() {
            commandExtension.install(registrar)
        }
    }
}

// MARK: - Logging

/// `@Loggable`'s generated logger is private to the file that declares it, so
/// `#log` cannot be used from an extension in another file. This file gets one
/// of its own rather than widening `RuntimeEngine`'s.
@Loggable(.private)
private enum RuntimeEngineCommandExtensionLog {
    static func commandExtensionAddedTooLate(_ name: String) {
        #log(.error, "Command extension '\(name, privacy: .public)' was added after handlers had already been installed on a connection. Connections established from now on will carry it, but the ones already up will not — to a host, those peers look like a build that predates these commands. Move the registration to this process's entry point.")
    }
}
