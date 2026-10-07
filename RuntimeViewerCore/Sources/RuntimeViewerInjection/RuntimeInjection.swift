import RuntimeViewerCore

/// Process injection, as a RuntimeEngine command extension.
///
/// This module is what `RuntimeViewerCore` deliberately is not: injection needs
/// MachInjector linked into the process on iOS and the privileged helper daemon
/// on macOS, while Core also builds for watchOS, tvOS and visionOS, where
/// neither exists. Core therefore knows nothing about injection at all — not the
/// protocol, not the wire types, not the command names.
///
/// What that costs is one call per process, below. What it buys is that the next
/// capability of this shape needs no edit inside Core either.
public enum RuntimeInjection {
    /// This process's own injection implementation, set by whoever has one.
    ///
    /// Per process rather than per engine: injection is a property of the
    /// machine, and every engine this process serves gives the same answer for
    /// it. A host asking a *remote* engine reaches that machine's own value
    /// through the connection, not through this one.
    ///
    /// `nil` is a valid, meaningful state, not an uninitialized one — the iOS
    /// variant without the injection entitlements leaves it unset on purpose.
    /// See ``RuntimeInjectionAvailability/withoutInjectionService`` for what
    /// each platform then answers.
    public static private(set) nonisolated(unsafe) var service: (any RuntimeInjectionService)?

    /// Installs the injection commands into the engine command table, and
    /// optionally records this process's injection implementation.
    ///
    /// **Every process that serves an engine must call this, including the ones
    /// that cannot inject.** The capability query is exactly how a host learns
    /// that they cannot: an engine that skipped registering is
    /// indistinguishable from a peer too old to have the command, so a device
    /// running the correct variant would be reported as unanswerable.
    ///
    /// Calling it in a process that only ever *asks* these commands of others
    /// is harmless too — it is idempotent, and with no local service every
    /// command has an honest empty answer. So the rule is one line: **if the
    /// process links this module, it calls this once**, with no need to work out
    /// which kind of process it is.
    ///
    /// Call it at the process's entry point, before any engine connects.
    /// Installation happens as a connection is established, so a call that
    /// arrives later reaches only the connections set up after it — see
    /// ``RuntimeViewerCore/RuntimeEngine/addCommandExtension(named:install:)``,
    /// which logs that case.
    ///
    /// - Parameter service: This machine's injection implementation, or `nil`
    ///   when it has none. Passing `nil` never clears a service already
    ///   recorded, so the order of two calls in one process does not matter.
    public static func install(service: (any RuntimeInjectionService)? = nil) {
        if let service {
            self.service = service
        }
        RuntimeEngine.addCommandExtension(named: commandExtensionName) { registrar in
            registrar.register(InjectionCapabilityCommand.self)
            registrar.register(ProcessListCommand.self)
            registrar.register(ApplicationIconsCommand.self)
            registrar.register(InjectIntoProcessCommand.self)
            registrar.register(StopKeepingProcessAwakeCommand.self)
        }
    }

    /// Identity for the command table's idempotence check. Not a wire value —
    /// the wire names are in `RuntimeInjection+CommandNames.swift`.
    private static let commandExtensionName = "RuntimeViewerInjection"
}
