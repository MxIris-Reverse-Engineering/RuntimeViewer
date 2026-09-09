import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerCommandLineInterface

/// Engines that are never connected: enough for every lookup and rendering
/// rule, which read `source`, `engineID`, `hostInfo` and `state` only.
enum TestEngines {
    static let localHost = RuntimeHostInfo(hostID: "host.local", hostName: "This Mac")
    static let phoneHost = RuntimeHostInfo(hostID: "host.phone", hostName: "iPhone")

    static func local(engineID: String = "engine.local") -> RuntimeEngine {
        RuntimeEngine(source: .local, engineID: engineID, hostInfo: localHost)
    }

    static func catalyst(engineID: String = "engine.catalyst") -> RuntimeEngine {
        RuntimeEngine(source: .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client), engineID: engineID, hostInfo: localHost)
    }

    static func attached(name: String, processIdentifier: Int32, isSandbox: Bool = false) -> RuntimeEngine {
        let identifier = RuntimeSource.Identifier(rawValue: String(processIdentifier))
        let source: RuntimeSource = isSandbox
            ? .localSocket(name: name, identifier: identifier, role: .client)
            : .remote(name: name, identifier: identifier, role: .client)
        return RuntimeEngine(source: source, engineID: "engine.attached.\(processIdentifier)", hostInfo: localHost)
    }

    static func bonjour(name: String, endpointKey: String, engineID: String? = nil) -> RuntimeEngine {
        RuntimeEngine(
            source: .bonjour(name: name, identifier: .init(rawValue: endpointKey), role: .client),
            engineID: engineID ?? "engine.bonjour.\(endpointKey)",
            hostInfo: phoneHost,
            bookmarkScope: .bonjour(deviceID: "device-1", processName: name, role: .client)
        )
    }

    static func mirrored(name: String, engineID: String = "engine.mirrored") -> RuntimeEngine {
        RuntimeEngine(source: .directTCP(name: name, host: "10.0.0.2", port: 4242, role: .client), engineID: engineID, hostInfo: phoneHost)
    }
}

/// A catalog over a snapshot the test controls. `terminate` records the
/// engine and drops it from the snapshot, the way the manager would.
final class StaticSourceCatalog: SourceCatalog, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotStorage: SourceCatalogSnapshot
    private var terminatedStorage: [RuntimeEngine] = []

    init(snapshot: SourceCatalogSnapshot = SourceCatalogSnapshot()) {
        snapshotStorage = snapshot
    }

    var terminated: [RuntimeEngine] {
        lock.withLock { terminatedStorage }
    }

    func update(_ snapshot: SourceCatalogSnapshot) {
        lock.withLock { snapshotStorage = snapshot }
    }

    func snapshot() -> SourceCatalogSnapshot {
        lock.withLock { snapshotStorage }
    }

    func terminate(_ engine: RuntimeEngine) {
        lock.withLock {
            terminatedStorage.append(engine)
            snapshotStorage.systemEngines.removeAll { $0 === engine }
            snapshotStorage.attachedEngines.removeAll { $0 === engine }
            snapshotStorage.bonjourEngines.removeAll { $0 === engine }
            snapshotStorage.mirroredEngines.removeAll { $0 === engine }
            snapshotStorage.sections = snapshotStorage.sections.map { section in
                var section = section
                section.engines.removeAll { $0 === engine }
                return section
            }
        }
    }
}

extension SourceCatalogSnapshot {
    /// A snapshot whose sections group the given engines by their host, the
    /// way `RuntimeEngineManager.rebuildSections` does (Bonjour engines that
    /// only carry mirrors are hidden by the manager; here every engine is shown).
    static func grouping(
        systemEngines: [RuntimeEngine] = [],
        attachedEngines: [RuntimeEngine] = [],
        bonjourEngines: [RuntimeEngine] = [],
        mirroredEngines: [RuntimeEngine] = [],
        hiddenBonjourEngines: [RuntimeEngine] = [],
        catalystHelperFailure: String? = nil
    ) -> SourceCatalogSnapshot {
        var sections: [SourceCatalogSection] = []
        for engine in systemEngines + attachedEngines + bonjourEngines + mirroredEngines {
            if let index = sections.firstIndex(where: { $0.hostIdentifier == engine.hostInfo.hostID }) {
                sections[index].engines.append(engine)
            } else {
                sections.append(SourceCatalogSection(hostIdentifier: engine.hostInfo.hostID, hostName: engine.hostInfo.hostName, engines: [engine]))
            }
        }
        return SourceCatalogSnapshot(
            systemEngines: systemEngines,
            attachedEngines: attachedEngines,
            bonjourEngines: bonjourEngines + hiddenBonjourEngines,
            mirroredEngines: mirroredEngines,
            sections: sections,
            catalystHelperFailure: catalystHelperFailure
        )
    }
}

struct StubProcessDirectory: ProcessDirectory {
    var processes: [RunningProcess]

    func runningProcesses() -> [RunningProcess] {
        processes
    }

    func process(withIdentifier processIdentifier: Int32) -> RunningProcess? {
        processes.first { $0.processIdentifier == processIdentifier }
    }
}

/// An attacher that answers from a script and records what it was asked.
final class StubProcessAttacher: ProcessAttaching, @unchecked Sendable {
    struct Request: Equatable {
        let name: String
        let processIdentifier: Int32
    }

    private let lock = NSLock()
    private var requestsStorage: [Request] = []
    private let outcome: Result<AttachOutcome, any Error>
    private let phases: [AttachPhase]

    init(outcome: Result<AttachOutcome, any Error>, phases: [AttachPhase] = [.installingPayload(platform: "macOS"), .injecting, .awaitingConnection(transport: "xpc")]) {
        self.outcome = outcome
        self.phases = phases
    }

    var requests: [Request] {
        lock.withLock { requestsStorage }
    }

    func attach(name: String, processIdentifier: Int32, progress: @escaping @Sendable (AttachPhase) -> Void) async throws -> AttachOutcome {
        lock.withLock { requestsStorage.append(Request(name: name, processIdentifier: processIdentifier)) }
        for phase in phases {
            progress(phase)
        }
        return try outcome.get()
    }
}

struct StubError: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Collects progress frames from a command.
final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var framesStorage: [CommandProgress] = []

    var frames: [CommandProgress] {
        lock.withLock { framesStorage }
    }

    var phases: [String] {
        frames.map(\.phase)
    }

    func record(_ progress: CommandProgress) {
        lock.withLock { framesStorage.append(progress) }
    }
}
