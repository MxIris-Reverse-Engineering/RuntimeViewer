import Combine
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
#if os(macOS)
import RuntimeViewerEngineManagement
#endif

/// The engines of one host (this Mac, a device, a peer), as the app's source
/// switcher groups them.
public struct SourceCatalogSection: Sendable {
    public var hostIdentifier: String
    public var hostName: String
    public var engines: [RuntimeEngine]

    public init(hostIdentifier: String, hostName: String, engines: [RuntimeEngine]) {
        self.hostIdentifier = hostIdentifier
        self.hostName = hostName
        self.engines = engines
    }
}

/// What a `RuntimeEngineManager` holds at one instant: its four engine groups
/// and the sections it built from them.
///
/// A value, so the lookup rules in ``EngineManagerSourceResolver`` are
/// functions of it and can be tested with engines that never connect.
public struct SourceCatalogSnapshot: Sendable {
    public var systemEngines: [RuntimeEngine]
    public var attachedEngines: [RuntimeEngine]
    public var bonjourEngines: [RuntimeEngine]
    public var mirroredEngines: [RuntimeEngine]
    /// Grouped by host, with management-only Bonjour connections left out —
    /// what `sources` prints.
    public var sections: [SourceCatalogSection]
    /// Why the Mac Catalyst runtime is missing, when the manager reported it.
    public var catalystHelperFailure: String?

    public init(
        systemEngines: [RuntimeEngine] = [],
        attachedEngines: [RuntimeEngine] = [],
        bonjourEngines: [RuntimeEngine] = [],
        mirroredEngines: [RuntimeEngine] = [],
        sections: [SourceCatalogSection] = [],
        catalystHelperFailure: String? = nil
    ) {
        self.systemEngines = systemEngines
        self.attachedEngines = attachedEngines
        self.bonjourEngines = bonjourEngines
        self.mirroredEngines = mirroredEngines
        self.sections = sections
        self.catalystHelperFailure = catalystHelperFailure
    }

    /// Every engine, including the Bonjour connections the sections hide.
    public var allEngines: [RuntimeEngine] {
        systemEngines + attachedEngines + bonjourEngines + mirroredEngines
    }
}

/// Where ``EngineManagerSourceResolver`` reads engines from and hands
/// terminations to. The manager in production; a fixed snapshot in tests.
public protocol SourceCatalog: Sendable {
    @MainActor func snapshot() -> SourceCatalogSnapshot

    /// Drops an engine the catalog holds: an attached process or a Bonjour peer.
    @MainActor func terminate(_ engine: RuntimeEngine)
}

// MARK: - Deriving source descriptions from engines

extension SourceKind {
    public init(source: RuntimeSource) {
        switch source {
        case .local:
            self = .local
        case .remote(_, let identifier, _):
            self = identifier == .macCatalyst ? .macCatalyst : .attachedXPC
        case .localSocket:
            self = .attachedSocket
        case .bonjour:
            self = .bonjour
        case .directTCP:
            self = .mirrored
        }
    }
}

extension SourceSelector {
    /// The selector that reaches `engine` again: `local`, `catalyst`,
    /// `pid:<n>` for an injected Mac process, `engine:<id>` for everything
    /// discovered over the network.
    public static func selector(for engine: RuntimeEngine) -> SourceSelector {
        switch SourceKind(source: engine.source) {
        case .local:
            return .local
        case .macCatalyst:
            return .macCatalyst
        case .attachedXPC, .attachedSocket:
            if let processIdentifier = Int32(engine.source.identifier) {
                return .attachedProcess(processIdentifier: processIdentifier)
            }
            return .engine(identifier: engine.engineID)
        case .bonjour, .mirrored:
            return .engine(identifier: engine.engineID)
        }
    }
}

extension SourceInfo {
    public init(engine: RuntimeEngine) {
        self.init(
            engineIdentifier: engine.engineID,
            displayName: engine.source.description,
            kind: SourceKind(source: engine.source),
            selector: .selector(for: engine),
            stableIdentity: engine.bookmarkScope.identityRawValue,
            isConnected: engine.state.isReady
        )
    }
}

extension SourcesResult {
    public init(snapshot: SourceCatalogSnapshot) {
        self.init(hosts: snapshot.sections.map { section in
            SourceHost(
                hostIdentifier: section.hostIdentifier,
                hostName: section.hostName,
                sources: section.engines.map(SourceInfo.init)
            )
        })
    }
}

// MARK: - The manager as a catalog

#if os(macOS)
/// Reads a `RuntimeEngineManager` and remembers the last Catalyst helper
/// failure it reported, so a `--source catalyst` miss can say why.
@MainActor
public final class RuntimeEngineManagerCatalog: SourceCatalog {
    private let engineManager: RuntimeEngineManager
    private var catalystHelperFailure: String?
    private var eventSubscription: AnyCancellable?

    public init(engineManager: RuntimeEngineManager) {
        self.engineManager = engineManager
        eventSubscription = engineManager.eventPublisher.sink { [weak self] event in
            guard case .catalystHelperUnavailable(let error) = event else { return }
            self?.catalystHelperFailure = error.localizedDescription
        }
    }

    public func snapshot() -> SourceCatalogSnapshot {
        SourceCatalogSnapshot(
            systemEngines: engineManager.systemRuntimeEngines,
            attachedEngines: engineManager.attachedRuntimeEngines,
            bonjourEngines: engineManager.bonjourRuntimeEngines,
            mirroredEngines: engineManager.mirroredEngines.values.elements,
            sections: engineManager.runtimeEngineSections.map { section in
                SourceCatalogSection(hostIdentifier: section.hostID, hostName: section.hostName, engines: section.engines)
            },
            catalystHelperFailure: catalystHelperFailure
        )
    }

    public func terminate(_ engine: RuntimeEngine) {
        engineManager.terminateRuntimeEngine(for: engine.source)
    }
}
#endif
