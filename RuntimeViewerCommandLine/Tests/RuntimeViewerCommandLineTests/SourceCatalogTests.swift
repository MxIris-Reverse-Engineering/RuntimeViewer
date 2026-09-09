import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerCommandLineInterface

/// How engines become sources: their kind, the selector that reaches them,
/// and which engine a selector names in a snapshot of the manager.
@Suite("Source catalog")
struct SourceCatalogTests {
    @Test("Each RuntimeSource maps to one source kind")
    func kinds() {
        #expect(SourceKind(source: TestEngines.local().source) == .local)
        #expect(SourceKind(source: TestEngines.catalyst().source) == .macCatalyst)
        #expect(SourceKind(source: TestEngines.attached(name: "Finder", processIdentifier: 550).source) == .attachedXPC)
        #expect(SourceKind(source: TestEngines.attached(name: "Mail", processIdentifier: 551, isSandbox: true).source) == .attachedSocket)
        #expect(SourceKind(source: TestEngines.bonjour(name: "SpringBoard", endpointKey: "device-1-77").source) == .bonjour)
        #expect(SourceKind(source: TestEngines.mirrored(name: "Finder").source) == .mirrored)
    }

    @Test("The selector of an engine is the one that resolves back to it")
    func selectors() {
        let local = TestEngines.local()
        let catalyst = TestEngines.catalyst()
        let finder = TestEngines.attached(name: "Finder", processIdentifier: 550)
        let mail = TestEngines.attached(name: "Mail", processIdentifier: 551, isSandbox: true)
        let springBoard = TestEngines.bonjour(name: "SpringBoard", endpointKey: "device-1-77")
        let mirrored = TestEngines.mirrored(name: "Finder")

        #expect(SourceSelector.selector(for: local) == .local)
        #expect(SourceSelector.selector(for: catalyst) == .macCatalyst)
        #expect(SourceSelector.selector(for: finder) == .attachedProcess(processIdentifier: 550))
        #expect(SourceSelector.selector(for: mail) == .attachedProcess(processIdentifier: 551))
        #expect(SourceSelector.selector(for: springBoard) == .engine(identifier: springBoard.engineID))
        #expect(SourceSelector.selector(for: mirrored) == .engine(identifier: mirrored.engineID))

        let snapshot = SourceCatalogSnapshot.grouping(
            systemEngines: [local, catalyst],
            attachedEngines: [finder, mail],
            bonjourEngines: [springBoard],
            mirroredEngines: [mirrored]
        )
        for engine in snapshot.allEngines {
            guard case .found(let resolved) = EngineManagerSourceResolver.lookup(.selector(for: engine), in: snapshot) else {
                Issue.record("\(engine.source.description) did not resolve through its own selector")
                continue
            }
            #expect(resolved === engine)
        }
    }

    @Test("Sources follow the manager's sections and report connection state")
    func sourcesFromSnapshot() {
        let local = TestEngines.local()
        let finder = TestEngines.attached(name: "Finder", processIdentifier: 550)
        let springBoard = TestEngines.bonjour(name: "SpringBoard", endpointKey: "device-1-77")
        let hidden = TestEngines.bonjour(name: "Other Mac", endpointKey: "mac-2", engineID: "engine.hidden")
        let snapshot = SourceCatalogSnapshot.grouping(systemEngines: [local], attachedEngines: [finder], bonjourEngines: [springBoard], hiddenBonjourEngines: [hidden])

        let result = SourcesResult(snapshot: snapshot)

        #expect(result.hosts.map(\.hostName) == ["This Mac", "iPhone"])
        #expect(result.hosts[0].sources.map(\.selector) == [.local, .attachedProcess(processIdentifier: 550)])
        #expect(result.hosts[1].sources.map(\.kind) == [.bonjour])
        #expect(result.hosts[1].sources[0].stableIdentity == springBoard.bookmarkScope.identityRawValue)
        #expect(result.sources.allSatisfy { !$0.isConnected })
        // Management-only Bonjour connections are not listed but still addressable.
        #expect(!result.sources.contains { $0.engineIdentifier == "engine.hidden" })
        guard case .found(let engine) = EngineManagerSourceResolver.lookup(.engine(identifier: "engine.hidden"), in: snapshot) else {
            Issue.record("The hidden Bonjour engine should resolve by identifier")
            return
        }
        #expect(engine === hidden)
    }

    @Test("A miss explains what to do next", arguments: [
        (SourceSelector.local, "has not started yet"),
        (.macCatalyst, "helper daemon"),
        (.attachedProcess(processIdentifier: 42), "attach 42"),
        (.attachedProcessNamed("Mail"), "attach Mail"),
        (.engine(identifier: "nope"), "sources --wait"),
    ] as [(SourceSelector, String)])
    func misses(selector: SourceSelector, hint: String) {
        guard case .missing(let failure) = EngineManagerSourceResolver.lookup(selector, in: SourceCatalogSnapshot()) else {
            Issue.record("\(selector) resolved against an empty snapshot")
            return
        }
        #expect(failure.code == .sourceUnavailable)
        #expect(failure.message.contains(hint), "\(failure.message)")
    }

    @Test("A Catalyst miss carries the helper failure the manager reported")
    func catalystMissCarriesReason() {
        let snapshot = SourceCatalogSnapshot(catalystHelperFailure: "helper tool not registered")
        guard case .missing(let failure) = EngineManagerSourceResolver.lookup(.macCatalyst, in: snapshot) else {
            Issue.record("catalyst resolved against an empty snapshot")
            return
        }
        #expect(failure.message.contains("helper tool not registered"))
    }

    @Test("A process name that several attached engines share must be disambiguated by pid")
    func ambiguousAttachedName() {
        let first = TestEngines.attached(name: "Helper", processIdentifier: 10)
        let second = TestEngines.attached(name: "helper", processIdentifier: 11)
        let snapshot = SourceCatalogSnapshot.grouping(attachedEngines: [first, second])

        guard case .missing(let failure) = EngineManagerSourceResolver.lookup(.attachedProcessNamed("HELPER"), in: snapshot) else {
            Issue.record("An ambiguous name resolved")
            return
        }
        #expect(failure.message.contains("pid:10"))
        #expect(failure.message.contains("pid:11"))

        guard case .found(let engine) = EngineManagerSourceResolver.lookup(.attachedProcess(processIdentifier: 11), in: snapshot) else {
            Issue.record("pid:11 did not resolve")
            return
        }
        #expect(engine === second)
    }
}

@Suite("Source resolver readiness", .timeLimit(.minutes(1)))
struct SourceResolverReadinessTests {
    @Test("An engine that is not connected is reported as unavailable once the grace period is over")
    func unconnectedEngineIsUnavailable() async {
        let catalog = StaticSourceCatalog(snapshot: .grouping(systemEngines: [TestEngines.local()]))
        let resolver = EngineManagerSourceResolver(catalog: catalog, attacher: nil, configuration: .init(startupGracePeriod: .zero))

        await #expect(throws: CommandFailure.self) {
            try await resolver.resolve(.local)
        }
        do {
            _ = try await resolver.resolve(.local)
        } catch let failure as CommandFailure {
            #expect(failure.code == .sourceUnavailable)
            #expect(failure.message.contains("is not connected"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A selector that misses right after start is retried until its engine appears")
    func gracePeriodCoversStartup() async throws {
        let sharedEngine = try await TestLocalEngine.shared()
        let catalog = StaticSourceCatalog()
        let resolver = EngineManagerSourceResolver(catalog: catalog, attacher: nil, configuration: .init(startupGracePeriod: .seconds(5), retryInterval: .milliseconds(20)))
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            catalog.update(.grouping(systemEngines: [sharedEngine]))
        }

        let started = ContinuousClock.now
        let engine = try await resolver.resolve(.local)

        #expect(engine === sharedEngine)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
