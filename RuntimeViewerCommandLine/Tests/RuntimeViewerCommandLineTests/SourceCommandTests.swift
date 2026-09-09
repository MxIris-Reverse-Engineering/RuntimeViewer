import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerCommandLineInterface

/// `attach`, `detach` and `sources --wait` through `EngineManagerSourceResolver`
/// and the executor, with the helper daemon and injection stubbed out.
@Suite("Source commands", .timeLimit(.minutes(1)))
struct SourceCommandTests {
    private static let finder = RunningProcess(processIdentifier: 550, name: "Finder", executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
    private static let mail = RunningProcess(processIdentifier: 551, name: "Mail", executablePath: "/System/Applications/Mail.app/Contents/MacOS/Mail")
    private static let helperOne = RunningProcess(processIdentifier: 600, name: "Helper", executablePath: "/Applications/A.app/Contents/MacOS/Helper")
    private static let helperTwo = RunningProcess(processIdentifier: 601, name: "Helper", executablePath: "/Applications/B.app/Contents/MacOS/Helper")

    private func makeResolver(
        catalog: StaticSourceCatalog = StaticSourceCatalog(),
        attacher: (any ProcessAttaching)?,
        processes: [RunningProcess] = [finder, mail, helperOne, helperTwo],
        helperPreflight: @escaping @Sendable () async throws -> Void = {},
        applicationBundleURL: URL? = URL(fileURLWithPath: "/Applications/RuntimeViewer.app")
    ) -> EngineManagerSourceResolver {
        EngineManagerSourceResolver(
            catalog: catalog,
            attacher: attacher,
            processDirectory: StubProcessDirectory(processes: processes),
            helperPreflight: helperPreflight,
            configuration: .init(startupGracePeriod: .zero, applicationBundleURL: applicationBundleURL)
        )
    }

    private func failure(_ operation: () async throws -> some Any) async -> CommandFailure? {
        do {
            _ = try await operation()
            return nil
        } catch let failure as CommandFailure {
            return failure
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    // MARK: - Attach

    @Test("Attaching by pid injects into that process and answers with a pid selector")
    func attachByProcessIdentifier() async throws {
        let engine = TestEngines.attached(name: "Finder", processIdentifier: 550)
        let attacher = StubProcessAttacher(outcome: .success(AttachOutcome(engine: engine, transport: "xpc", payloadPlatform: "macOS")))
        let resolver = makeResolver(attacher: attacher)
        let progress = ProgressCollector()

        let result = try await resolver.attach(.processIdentifier(550)) { progress.record($0) }

        #expect(attacher.requests == [.init(name: "Finder", processIdentifier: 550)])
        #expect(result.selector == .attachedProcess(processIdentifier: 550))
        #expect(result.processName == "Finder")
        #expect(result.transport == "xpc")
        #expect(result.engineIdentifier == engine.engineID)
        #expect(!result.wasAlreadyAttached)
        await settle(milliseconds: 50)
        #expect(progress.phases == ["preparing", "installing payload", "injecting", "awaiting connection"])
    }

    @Test("Attaching by name matches the process name or the executable name, case-insensitively", arguments: ["mail", "MAIL", "Mail"])
    func attachByName(name: String) async throws {
        let engine = TestEngines.attached(name: "Mail", processIdentifier: 551, isSandbox: true)
        let attacher = StubProcessAttacher(outcome: .success(AttachOutcome(engine: engine, transport: "localSocket", payloadPlatform: "macOS")))
        let resolver = makeResolver(attacher: attacher)

        let result = try await resolver.attach(.processName(name)) { _ in }

        #expect(attacher.requests == [.init(name: "Mail", processIdentifier: 551)])
        #expect(result.selector == .attachedProcess(processIdentifier: 551))
        #expect(result.transport == "localSocket")
    }

    @Test("A name several processes share is refused with their pids")
    func ambiguousName() async {
        let attacher = StubProcessAttacher(outcome: .failure(StubError(message: "must not be reached")))
        let resolver = makeResolver(attacher: attacher)

        let failure = await failure { try await resolver.attach(.processName("helper")) { _ in } }

        #expect(failure?.code == .ambiguousProcessName)
        #expect(failure?.message.contains("600") == true)
        #expect(failure?.message.contains("601") == true)
        #expect(attacher.requests.isEmpty)
    }

    @Test("An unknown name or a dead pid is processNotFound")
    func unknownProcess() async {
        let attacher = StubProcessAttacher(outcome: .failure(StubError(message: "must not be reached")))
        let resolver = makeResolver(attacher: attacher)

        let byName = await failure { try await resolver.attach(.processName("NoSuchProcess")) { _ in } }
        // Above pid_max, so no process can carry it and kill(2) reports ESRCH.
        let byIdentifier = await failure { try await resolver.attach(.processIdentifier(2_000_000_000)) { _ in } }

        #expect(byName?.code == .processNotFound)
        #expect(byIdentifier?.code == .processNotFound)
        #expect(attacher.requests.isEmpty)
    }

    @Test("A process that is attached already is answered without injecting again")
    func alreadyAttached() async throws {
        let existing = TestEngines.attached(name: "Finder", processIdentifier: 550)
        let catalog = StaticSourceCatalog(snapshot: .grouping(attachedEngines: [existing]))
        let attacher = StubProcessAttacher(outcome: .failure(StubError(message: "must not be reached")))
        let resolver = makeResolver(catalog: catalog, attacher: attacher)

        let result = try await resolver.attach(.processIdentifier(550)) { _ in }

        #expect(result.wasAlreadyAttached)
        #expect(result.selector == .attachedProcess(processIdentifier: 550))
        #expect(result.engineIdentifier == existing.engineID)
        #expect(attacher.requests.isEmpty)
    }

    @Test("An unreachable helper daemon fails before anything is injected")
    func helperUnavailable() async {
        let attacher = StubProcessAttacher(outcome: .failure(StubError(message: "must not be reached")))
        let resolver = makeResolver(attacher: attacher, helperPreflight: { throw StubError(message: "connection refused") })

        let failure = await failure { try await resolver.attach(.processIdentifier(550)) { _ in } }

        #expect(failure?.code == .helperUnavailable)
        #expect(failure?.message.contains("connection refused") == true)
        #expect(failure?.message.contains("Helper Service") == true)
        #expect(attacher.requests.isEmpty)
    }

    @Test("A simulator process is reached over Bonjour and answered with an engine selector")
    func simulatorAttach() async throws {
        let engine = TestEngines.bonjour(name: "SpringBoard", endpointKey: "device-1-550")
        let attacher = StubProcessAttacher(
            outcome: .success(AttachOutcome(engine: engine, transport: AttachOutcome.simulatorBonjourTransport, payloadPlatform: "iOS Simulator")),
            phases: [.installingPayload(platform: "iOS Simulator"), .injecting, .awaitingConnection(transport: AttachOutcome.simulatorBonjourTransport)]
        )
        let resolver = makeResolver(attacher: attacher)

        let result = try await resolver.attach(.processIdentifier(550)) { _ in }

        #expect(result.selector == .engine(identifier: engine.engineID))
        #expect(result.payloadPlatform == "iOS Simulator")
    }

    @Test("An injection error is attachFailed with the underlying message")
    func injectionFailure() async {
        let attacher = StubProcessAttacher(outcome: .failure(StubError(message: "task_for_pid denied")))
        let resolver = makeResolver(attacher: attacher)

        let failure = await failure { try await resolver.attach(.processIdentifier(550)) { _ in } }

        #expect(failure?.code == .attachFailed)
        #expect(failure?.message.contains("task_for_pid denied") == true)
    }

    @Test("A host without an attacher refuses to attach")
    func noAttacher() async {
        let resolver = makeResolver(attacher: nil)

        let failure = await failure { try await resolver.attach(.processIdentifier(550)) { _ in } }

        #expect(failure?.code == .sourceUnavailable)
    }

    // MARK: - Detach

    @Test("Detaching an attached process terminates its engine and reports it")
    func detachAttached() async throws {
        let finder = TestEngines.attached(name: "Finder", processIdentifier: 550)
        let catalog = StaticSourceCatalog(snapshot: .grouping(systemEngines: [TestEngines.local()], attachedEngines: [finder]))
        let resolver = makeResolver(catalog: catalog, attacher: nil)

        let result = try await resolver.detach(.attachedProcessNamed("finder"))

        #expect(catalog.terminated.map(\.engineID) == [finder.engineID])
        #expect(result.selector == .attachedProcess(processIdentifier: 550))
        #expect(result.kind == .attachedXPC)
        #expect(await resolver.listSources().sources.map(\.selector) == [.local])
    }

    @Test("Only attached processes and Bonjour peers can be detached", arguments: [
        SourceSelector.local,
        .macCatalyst,
        .engine(identifier: "engine.mirrored"),
    ])
    func detachRefusesOtherKinds(selector: SourceSelector) async {
        let catalog = StaticSourceCatalog(snapshot: .grouping(
            systemEngines: [TestEngines.local(), TestEngines.catalyst()],
            mirroredEngines: [TestEngines.mirrored(name: "Finder")]
        ))
        let resolver = makeResolver(catalog: catalog, attacher: nil)

        let failure = await failure { try await resolver.detach(selector) }

        #expect(failure?.code == .invalidArgument)
        #expect(catalog.terminated.isEmpty)
    }

    @Test("Detaching something that is not there is sourceUnavailable")
    func detachMissing() async {
        let resolver = makeResolver(attacher: nil)

        let failure = await failure { try await resolver.detach(.attachedProcess(processIdentifier: 550)) }

        #expect(failure?.code == .sourceUnavailable)
    }

    // MARK: - Sources with --wait

    @Test("sources --wait answers once the list has settled, before the deadline")
    func waitSettlesEarly() async throws {
        let catalog = StaticSourceCatalog(snapshot: .grouping(systemEngines: [TestEngines.local()]))
        let executor = CommandExecutor(sourceResolver: makeResolver(catalog: catalog, attacher: nil))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            catalog.update(.grouping(systemEngines: [TestEngines.local()], bonjourEngines: [TestEngines.bonjour(name: "SpringBoard", endpointKey: "device-1-77")]))
        }

        let started = ContinuousClock.now
        let result = try await executor.execute(.listSources(ListSourcesCommand(waitSeconds: 30)))
        let elapsed = ContinuousClock.now - started

        guard case .sources(let sources) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(sources.hosts.map(\.hostName) == ["This Mac", "iPhone"])
        // The change lands at 0.3 s and the settle period is 3 s.
        #expect(elapsed >= .seconds(3))
        #expect(elapsed < .seconds(10))
    }

    @Test("sources without --wait answers at once")
    func noWaitAnswersAtOnce() async throws {
        let catalog = StaticSourceCatalog(snapshot: .grouping(systemEngines: [TestEngines.local()]))
        let executor = CommandExecutor(sourceResolver: makeResolver(catalog: catalog, attacher: nil))

        let started = ContinuousClock.now
        let result = try await executor.execute(.listSources(ListSourcesCommand()))

        #expect(ContinuousClock.now - started < .seconds(1))
        guard case .sources(let sources) = result else {
            Issue.record("Unexpected result \(result)")
            return
        }
        #expect(sources.sources.map(\.selector) == [.local])
    }
}
