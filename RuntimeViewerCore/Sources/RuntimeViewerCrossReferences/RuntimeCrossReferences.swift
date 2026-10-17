import RuntimeViewerCore

/// Cross references — what a function calls, who calls it, which functions
/// use a type — read from the
/// arm64 machine code of the images an engine's process maps, as a
/// RuntimeEngine command extension.
///
/// Like `RuntimeViewerInjection`, this lives outside `RuntimeViewerCore`: the
/// analysis is MachOSwiftSection's `CrossReferenceAnalysis`, and Core knows
/// nothing about it — not the wire types, not the command names. Evolution
/// proposal `cross-references`.
public enum RuntimeCrossReferences {
    /// Installs the cross-reference commands into the engine command table.
    ///
    /// **Every process that serves an engine and links this module calls this
    /// once, at its entry point, before any engine connects** — the same rule,
    /// and for the same reason, as `RuntimeInjection.install(service:)`: an
    /// engine whose process skipped it has no handler for these commands, and
    /// a dispatch that finds no handler looks exactly like a peer built before
    /// they existed. Calling it in a process that only ever asks these
    /// commands of others is harmless; it is idempotent.
    public static func install() {
        RuntimeEngine.addCommandExtension(named: commandExtensionName) { registrar in
            registrar.register(CalleesCommand.self)
            registrar.registerProgress(CallersCommand.self)
            registrar.registerProgress(TypeReferencesCommand.self)
        }
    }

    /// Identity for the command table's idempotence check. Not a wire value —
    /// the wire names are in `RuntimeCrossReferences+CommandNames.swift`.
    private static let commandExtensionName = "RuntimeViewerCrossReferences"
}
