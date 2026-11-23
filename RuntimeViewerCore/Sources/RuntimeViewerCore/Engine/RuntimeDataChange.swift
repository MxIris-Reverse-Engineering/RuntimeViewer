import Foundation

/// A fine-grained event describing a change in `RuntimeEngine`'s runtime data.
///
/// Replaces the prior pattern of broadcasting a unit `reloadData` signal for
/// every kind of change. Carrying the change kind in the payload lets
/// downstream consumers (e.g. the sidebar) apply minimal updates instead of
/// rebuilding their entire data source.
///
/// Wire-encoded across XPC/TCP for server -> client mirroring; the `RuntimeObject`
/// payloads in `.specializationAdded` are themselves `Codable & Sendable`.
public enum RuntimeDataChange: Codable, Sendable, Hashable {
    /// Indicates that the entire runtime data set should be considered stale.
    /// Consumers typically respond by re-querying `objects(in:)` for the
    /// images they care about. `isReloadImageNodes` mirrors the parameter on
    /// `RuntimeEngine.reloadData(isReloadImageNodes:)` and indicates whether
    /// the top-level image-node tree itself changed.
    case fullReload(isReloadImageNodes: Bool)

    /// Emitted after a successful user-driven generic specialization. The
    /// sidebar can locate `parent` in its current node tree and append `child`
    /// as a new specialized descendant without rebuilding the rest of the
    /// tree.
    case specializationAdded(parent: RuntimeObject, child: RuntimeObject)

    /// The serving process's SDK type index finished a batch for the SDK platform
    /// `platformName` (`macosx`, `maccatalyst`, …): interfaces of that platform's images now
    /// print more of their `__C` types under their module and Swift name, and Objective-C headers
    /// carry more of the SDK's Swift naming. The engine has already dropped what it printed
    /// before; consumers refetch what they show. Only a serving process with a type index
    /// (a Mac's services and the command-line host) sends it.
    case typeNamesResolved(platformName: String)
}
