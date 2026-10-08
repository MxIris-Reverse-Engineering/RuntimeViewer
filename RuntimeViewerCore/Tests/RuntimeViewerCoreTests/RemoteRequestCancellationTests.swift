#if canImport(Network) && os(macOS)

import Testing
import Foundation
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// Cancelling the caller of a request that crosses a connection.
///
/// A transport cannot interrupt a request it sent: SwiftyXPC's send and the
/// socket channel's both wait for the reply whatever happens to the caller,
/// and the serving peer runs each request in a task nobody holds a handle
/// to. Without a cancellation of its own the caller of a corpus build waited
/// for the whole build, and the serving process kept building; a superseded
/// search kept delivering its batches (PR121.29).
@Suite("Remote request cancellation", .serialized)
struct RemoteRequestCancellationTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// How long a cancelled caller may take to return. Well under the time
    /// the serving process needs for the work, which is what an uncancelled
    /// caller waits for.
    private static let promptReturn: Duration = .seconds(2)

    /// The engine every pair of this suite serves, Foundation and libobjc
    /// indexed once. Each test leaves it without a corpus build under way.
    private static let servingEngine = Task<RuntimeEngine, Swift.Error> {
        try await RemoteEnginePair.makeServingEngine(label: "remote-request-cancellation", loading: [foundationPath, libobjcPath])
    }

    @Test("Cancelling a forwarded corpus build returns at once and stops the build in the serving process", arguments: RemoteEnginePair.Transport.allCases)
    func cancellingForwardedBuildStopsTheServingProcess(transport: RemoteEnginePair.Transport) async throws {
        let pair = try await RemoteEnginePair.make(transport, label: "remote-request-cancellation.build.\(transport)", serving: Self.servingEngine.value)
        defer { Task { await pair.stop() } }

        let progress = MarkedEventCounter()
        let build = Task {
            try await pair.client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
                progress.record()
            }
        }
        let didStart = await waitForCondition(timeout: .seconds(60)) { progress.count > 0 }
        try #require(didStart, "the build never reported progress")

        progress.mark()
        build.cancel()
        let cancelledAt = ContinuousClock.now
        let result = await build.result
        let waited = ContinuousClock.now - cancelledAt

        #expect(waited < Self.promptReturn, "the caller waited \(waited) after cancelling")
        #expect(throws: CancellationError.self) { try result.get() }
        let stoppedServing = await waitForCondition(timeout: .seconds(5)) {
            let coverage = try? await pair.serving.interfaceCorpusCoverage()
            return coverage?.statesByImagePath[Self.foundationPath] == nil
        }
        #expect(stoppedServing, "the serving process kept building after the caller cancelled")
        // Long enough for pushes already on their way to arrive.
        try await Task.sleep(for: .milliseconds(500))
        #expect(progress.countAfterMark == 0, "\(progress.countAfterMark) progress reports reached the caller after it cancelled")
    }

    @Test("A peer that ignores the cancellation does not hold the caller")
    func peerIgnoringCancellationDoesNotHoldTheCaller() async throws {
        // A no-op in place of the serving side's cancellation handler.
        let pair = try await RemoteEnginePair.make(.socket, label: "remote-request-cancellation.ignored", serving: Self.servingEngine.value) { connection in
            connection.setMessageHandler(name: "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.cancelRequest") { (_: IgnoredCancellation) in }
        }
        defer { Task { await pair.stop() } }

        let progress = MarkedEventCounter()
        let build = Task {
            try await pair.client.buildInterfaceCorpus(for: Self.foundationPath, transformer: .default) { _ in
                progress.record()
            }
        }
        let didStart = await waitForCondition(timeout: .seconds(60)) { progress.count > 0 }
        try #require(didStart, "the build never reported progress")

        progress.mark()
        build.cancel()
        let cancelledAt = ContinuousClock.now
        let result = await build.result
        let waited = ContinuousClock.now - cancelledAt

        #expect(waited < Self.promptReturn, "the caller waited \(waited) for a peer that ignored the cancellation")
        #expect(throws: CancellationError.self) { try result.get() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(progress.countAfterMark == 0, "\(progress.countAfterMark) progress reports reached the caller after it cancelled")
        // The serving side never heard of the cancellation. Drop the build
        // and wait until it is gone, or the next test joins a build that is
        // being cancelled.
        try await pair.serving.evictInterfaceCorpus(for: Self.foundationPath)
        let buildEnded = await waitForCondition(timeout: .seconds(10)) {
            let coverage = try? await pair.serving.interfaceCorpusCoverage()
            return coverage?.statesByImagePath[Self.foundationPath] == nil
        }
        #expect(buildEnded)
    }

    /// The caller's own consumer holds the search back — over XPC every push
    /// is a round trip, over a socket the reply waits for the pushes sent
    /// before it — so an uncancelled caller returns only once its consumer is
    /// done.
    @Test("Cancelling a forwarded search returns without waiting for the batches under way", arguments: RemoteEnginePair.Transport.allCases)
    func cancellingForwardedSearchReturnsAtOnce(transport: RemoteEnginePair.Transport) async throws {
        let pair = try await RemoteEnginePair.make(transport, label: "remote-request-cancellation.search.\(transport)", serving: Self.servingEngine.value)
        defer { Task { await pair.stop() } }
        _ = try await pair.serving.buildInterfaceCorpus(for: Self.libobjcPath, transformer: .default)

        let batches = MarkedEventCounter()
        let search = Task {
            try await pair.client.searchInterfaces(RuntimeInterfaceSearchQuery(text: "NSObject")) { _ in
                batches.record()
                // A consumer slower than the cancellation.
                try? await Task.sleep(for: .seconds(4))
            }
        }
        let didStart = await waitForCondition(timeout: .seconds(30)) { batches.count > 0 }
        try #require(didStart, "the search never delivered a batch")

        search.cancel()
        let cancelledAt = ContinuousClock.now
        let result = await search.result
        let waited = ContinuousClock.now - cancelledAt

        #expect(waited < Self.promptReturn, "the caller waited \(waited) after cancelling")
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// `typeRelationships` became a progress request — one that reports
    /// nothing — so that it can carry a request identifier.
    @Test("A relationship query still answers across a connection", arguments: RemoteEnginePair.Transport.allCases)
    func relationshipQueryAnswersAcrossConnection(transport: RemoteEnginePair.Transport) async throws {
        let pair = try await RemoteEnginePair.make(transport, label: "remote-request-cancellation.relationships.\(transport)", serving: Self.servingEngine.value)
        defer { Task { await pair.stop() } }
        let query = RuntimeTypeRelationshipsQuery(text: "NSObject", matchMode: .matchingWord, relationship: .descendants, imagePaths: [Self.libobjcPath])

        let forwarded = try await pair.client.typeRelationships(query)
        let local = try await pair.serving.typeRelationships(query)

        #expect(!forwarded.isEmpty)
        #expect(forwarded == local)
    }
}

// MARK: - Which requests can be withdrawn

/// What travels on the wire: the commands that opt in carry a request
/// identifier, every command a peer of an earlier release serves carries
/// none — so `cancelRequest` can only ever name a request of a command added
/// together with it.
@Suite("Remote request identifiers", .serialized)
struct RemoteRequestIdentifierTests {
    /// The envelope's routing fields, read from whatever a client sends.
    private struct ReceivedEnvelope: Codable, Equatable {
        let progressToken: String?
        let requestIdentifier: String?
    }

    private actor ReceivedEnvelopes {
        private(set) var envelopesByCommandName: [String: ReceivedEnvelope] = [:]

        func record(_ envelope: ReceivedEnvelope, for commandName: String) {
            envelopesByCommandName[commandName] = envelope
        }
    }

    private struct DeclinedRequest: LocalizedError {
        var errorDescription: String? { "declined by the test peer" }
    }

    @Test("Only the commands that opt in name their requests")
    func onlyOptedInCommandsNameTheirRequests() async throws {
        let received = ReceivedEnvelopes()
        let peer = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "remote-request-identifiers.client", host: "127.0.0.1", port: peer.port, role: .client),
            engineID: "remote-request-identifiers.client"
        )
        defer { Task { await client.stop(); peer.stop() } }
        try await client.connect()
        let deadline = ContinuousClock.now + .seconds(5)
        while peer.state != .connected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let commandNames = [
            RuntimeEngine.BuildInterfaceCorpusCommand.commandName,
            RuntimeEngine.SearchInterfacesCommand.commandName,
            RuntimeEngine.SearchMembersCommand.commandName,
            RuntimeEngine.TypeRelationshipsCommand.commandName,
            RuntimeEngine.ObjectsInImageCommand.commandName,
            RuntimeEngine.LoadImageWithProgressCommand.commandName,
        ]
        for commandName in commandNames {
            peer.setMessageHandler(name: commandName) { (envelope: ReceivedEnvelope) -> RuntimeEngineEmpty in
                await received.record(envelope, for: commandName)
                throw DeclinedRequest()
            }
        }

        _ = try? await client.buildInterfaceCorpus(for: "/usr/lib/libobjc.A.dylib", transformer: .default)
        _ = try? await client.searchInterfaces(RuntimeInterfaceSearchQuery(text: "NSObject")) { _ in }
        _ = try? await client.searchMembers(RuntimeMemberSearchQuery(text: "init")) { _ in }
        _ = try? await client.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSObject", relationship: .ancestors))
        _ = try? await client.objects(in: "/usr/lib/libobjc.A.dylib")
        try? await client.loadImage(at: "/usr/lib/libobjc.A.dylib") { _ in }

        let envelopes = await received.envelopesByCommandName
        for commandName in commandNames.prefix(4) {
            #expect(envelopes[commandName]?.requestIdentifier != nil, "\(commandName) carries no request identifier: \(String(describing: envelopes[commandName]))")
        }
        for commandName in commandNames.suffix(2) {
            #expect(envelopes[commandName] != nil, "\(commandName) never reached the peer")
            #expect(envelopes[commandName]?.requestIdentifier == nil, "\(commandName), which earlier releases serve, carries a request identifier")
        }
    }
}

// MARK: - The two halves of the protocol

@Suite("Remote request cancellation parts")
struct RemoteRequestCancellationPartTests {
    /// A cancellation can be handled before the request it names: over a
    /// socket it waits on the ordered handler tail while the request runs in
    /// a task of its own, and over XPC both are tasks of their own.
    @Test("A cancellation that arrives before its request cancels the request the moment it starts")
    func earlyCancellationCancelsTheRequest() async throws {
        let inboundRequests = RuntimeEngineInboundRequests()
        await inboundRequests.cancel("early")

        let startedAt = ContinuousClock.now
        await #expect(throws: CancellationError.self) {
            try await inboundRequests.run("early") {
                try await Task.sleep(for: .seconds(10))
            }
        }
        #expect(ContinuousClock.now - startedAt < .seconds(5))
    }

    @Test("Early cancellations are remembered up to a bound, oldest forgotten first")
    func earlyCancellationsAreBounded() async throws {
        let inboundRequests = RuntimeEngineInboundRequests()
        for index in 0 ... RuntimeEngineInboundRequests.maximumEarlyCancellationCount {
            await inboundRequests.cancel("early-\(index)")
        }

        // The oldest one aged out: its request runs to its end.
        let answer = try await inboundRequests.run("early-0") { 42 }
        #expect(answer == 42)
        // The newest one is still waiting for its request.
        await #expect(throws: CancellationError.self) {
            try await inboundRequests.run("early-\(RuntimeEngineInboundRequests.maximumEarlyCancellationCount)") {
                try await Task.sleep(for: .seconds(10))
            }
        }
    }

    @Test("A cancellation stops a request under way, and touches no other")
    func cancellationStopsTheNamedRequestOnly() async throws {
        let inboundRequests = RuntimeEngineInboundRequests()
        let started = MarkedEventCounter()
        let named = Task {
            try await inboundRequests.run("named") {
                started.record()
                try await Task.sleep(for: .seconds(10))
            }
        }
        let other = Task {
            try await inboundRequests.run("other") {
                started.record()
                try await Task.sleep(for: .milliseconds(300))
                return 7
            }
        }
        _ = await waitForCondition { started.count == 2 }

        await inboundRequests.cancel("named")

        await #expect(throws: CancellationError.self) { try await named.value }
        #expect(try await other.value == 7)
    }

    @Test("A forwarded request cancelled before it is sent is never sent")
    func requestCancelledBeforeSendingIsNotSent() async throws {
        let forwardedRequest = RuntimeEngineForwardedRequest<Int>()
        let sent = MarkedEventCounter()

        #expect(forwardedRequest.cancel() == false, "nothing was out, so the peer has nothing to withdraw")
        await #expect(throws: CancellationError.self) {
            try await forwardedRequest.response {
                sent.record()
                return 1
            }
        }
        #expect(sent.count == 0)
        #expect(forwardedRequest.isCancelled)
    }

    @Test("A forwarded request's caller stops waiting the moment it cancels; the reply that follows is dropped")
    func cancelledCallerStopsWaiting() async throws {
        let forwardedRequest = RuntimeEngineForwardedRequest<Int>()
        let replyGate = ReplyGate()
        let caller = Task {
            try await forwardedRequest.response {
                try await replyGate.reply()
            }
        }
        _ = await waitForCondition { await replyGate.isWaiting }

        #expect(forwardedRequest.cancel(), "the request was out and unanswered")
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(forwardedRequest.cancel() == false, "a second cancellation has nothing left to withdraw")

        // The peer's reply still ends the send; nobody hears of it.
        await replyGate.open(with: 5)
        #expect(forwardedRequest.isCancelled)
    }

    @Test("A forwarded request answered before any cancellation returns the answer")
    func answeredRequestReturnsTheAnswer() async throws {
        let forwardedRequest = RuntimeEngineForwardedRequest<Int>()

        let answer = try await forwardedRequest.response { 3 }

        #expect(answer == 3)
        #expect(forwardedRequest.cancel() == false, "an answered request has nothing to withdraw")
        #expect(!forwardedRequest.isCancelled)
    }
}

/// A reply that comes when the test says so.
private actor ReplyGate {
    private var continuation: CheckedContinuation<Int, Never>?

    var isWaiting: Bool { continuation != nil }

    func reply() async throws -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open(with value: Int) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The cancellation's payload as the wire carries it, for a handler that
/// reads it and does nothing.
private struct IgnoredCancellation: Codable {
    let requestIdentifier: String
}

#endif
