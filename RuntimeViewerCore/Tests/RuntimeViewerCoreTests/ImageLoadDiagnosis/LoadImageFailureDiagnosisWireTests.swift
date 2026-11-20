#if canImport(Network) && os(macOS)

import Foundation
import Testing
#if canImport(SwiftyXPC)
import SwiftyXPC
#endif
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// A refused load's diagnosis rides in the load's own reply, asked for by an
/// optional field of the request (`CommunicationAndEngineArchitecture.md`
/// §4.4): a peer of an earlier version skips the field and fails with dyld's
/// message, and a requester of an earlier version, which never sets it, reads
/// the reply it always read. No new command reaches a peer that may be old —
/// an injected payload of an earlier release drops its connection on one it
/// does not know (PR121.73).
@Suite("Load failure diagnosis over the wire", .serialized)
struct LoadImageFailureDiagnosisWireTests {
    /// `LoadImageCommand`'s request as releases before the diagnosis wrote and
    /// read it. Frozen: never replace it with the current type.
    private struct ShippedLoadImageRequest: Codable, Sendable {
        let path: String
    }

    private static let appRpaths = ["@executable_path/../Frameworks", "@loader_path/Frameworks"]

    /// Foo links Bar through `@rpath/`; both are in an app's Frameworks, and
    /// Foo's rpath is written for the app's executable — so Foo fails here.
    private static func makeFooMissingBar() throws -> ImageLoadFixtures.HostApplication {
        try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: appRpaths),
        ])
    }

    private static func canonical(_ path: String) -> String {
        RuntimeImageLoadDiagnostician.canonicalPath(path)
    }

    // MARK: - This build on both ends

    @Test("An engine in process fails a load with its diagnosis")
    func inProcessLoadFailureCarriesDiagnosis() async throws {
        let application = try Self.makeFooMissingBar()
        let engine = RuntimeEngine(source: .local, engineID: "load-failure-diagnosis.in-process")
        try await engine.connect()
        defer { Task { await engine.stop() } }

        let error = await #expect(throws: RuntimeImageLoadError.self) {
            try await engine.loadImageInServingProcess(at: application.framework("Foo").binaryPath)
        }

        Self.expectDiagnosis(in: error, of: application)
    }

    @Test("A forwarded load fails with the serving process's diagnosis", arguments: RemoteEnginePair.Transport.allCases)
    func forwardedLoadFailureCarriesDiagnosis(transport: RemoteEnginePair.Transport) async throws {
        let application = try Self.makeFooMissingBar()
        let label = "load-failure-diagnosis.\(transport)"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(transport, label: label, serving: serving)
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }

        let error = await #expect(throws: RuntimeImageLoadError.self) {
            try await pair.client.loadImageInServingProcess(at: application.framework("Foo").binaryPath)
        }

        Self.expectDiagnosis(in: error, of: application)
    }

    @Test("A load that succeeds still succeeds", arguments: RemoteEnginePair.Transport.allCases)
    func successfulLoadStillSucceeds(transport: RemoteEnginePair.Transport) async throws {
        let application = try Self.makeFooMissingBar()
        let label = "load-failure-diagnosis.success.\(transport)"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(transport, label: label, serving: serving)
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }

        try await pair.client.loadImageInServingProcess(at: application.framework("Bar").binaryPath)

        // dyld lists the image under its real path (`/private/var/…`).
        #expect(try await serving.isImageLoaded(path: Self.canonical(application.framework("Bar").binaryPath)))
    }

    @Test("A relay of this build forwards the field and the reply unchanged")
    func relayForwardsTheFieldAndTheReplyUnchanged() async throws {
        let application = try Self.makeFooMissingBar()
        let label = "load-failure-diagnosis.relay"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let upstream = try await RemoteEnginePair.make(.socket, label: label, serving: serving)
        let relayConnection = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let client = RuntimeEngine(
            source: .directTCP(name: "\(label).client", host: "127.0.0.1", port: relayConnection.port, role: .client),
            engineID: "\(label).client"
        )
        defer {
            Task {
                await client.stop()
                relayConnection.stop()
                await upstream.stop()
                await serving.stop()
            }
        }
        try await client.connect()
        try await Self.waitUntilConnected(relayConnection)
        RuntimeEngine.registerSharedHandlers(on: relayConnection, engine: upstream.client)

        let error = await #expect(throws: RuntimeImageLoadError.self) {
            try await client.loadImageInServingProcess(at: application.framework("Foo").binaryPath)
        }

        Self.expectDiagnosis(in: error, of: application)
    }

    // MARK: - Peers of earlier versions

    @Test("A server that predates the field fails with dyld's message, and the client reads what it can from it", arguments: RemoteEnginePair.Transport.allCases)
    func olderServerFailsWithTextOnly(transport: RemoteEnginePair.Transport) async throws {
        let application = try Self.makeFooMissingBar()
        let foo = application.framework("Foo")
        let label = "load-failure-diagnosis.shipped-server.\(transport)"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(transport, label: label, serving: serving) { connection in
            connection.setMessageHandler(name: RuntimeEngine.LoadImageCommand.commandName) { (request: ShippedLoadImageRequest) -> RuntimeEngineEmpty in
                try DyldUtilities.loadImage(at: request.path)
                return RuntimeEngineEmpty()
            }
        }
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }

        let error = await #expect(throws: (any Error).self) {
            try await pair.client.loadImageInServingProcess(at: foo.binaryPath)
        }

        let thrown = try #require(error)
        #expect(!(thrown is RuntimeImageLoadError))
        let diagnosis = RuntimeImageLoadDiagnosis(dyldMessage: thrown.localizedDescription, imagePath: foo.binaryPath)
        #expect(diagnosis.isFromMessageOnly)
        #expect(diagnosis.failure.kind == .imageNotFound)
        #expect(diagnosis.failure.missingInstallName == application.framework("Bar").installName)
    }

    @Test("A requester that predates the field gets the empty reply and the thrown failure it always got")
    func olderRequesterGetsTheReplyItAlwaysGot() async throws {
        let application = try Self.makeFooMissingBar()
        let label = "load-failure-diagnosis.shipped-client"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let server = try await RuntimeDirectTCPServerConnection(port: 0, waitForConnection: false)
        let shippedClient = try await RuntimeDirectTCPClientConnection(host: "127.0.0.1", port: server.port)
        defer {
            Task {
                shippedClient.stop()
                server.stop()
                await serving.stop()
            }
        }
        try await Self.waitUntilConnected(server)
        RuntimeEngine.registerSharedHandlers(on: server, engine: serving)

        // Foo first: once Bar is loaded, Foo finds it by its install name.
        let error = await #expect(throws: (any Error).self) {
            let _: RuntimeEngineEmpty = try await shippedClient.sendMessage(
                name: RuntimeEngine.LoadImageCommand.commandName,
                request: ShippedLoadImageRequest(path: application.framework("Foo").binaryPath),
                timeout: 30
            )
        }
        #expect(error?.localizedDescription.contains("Library not loaded") == true)

        let _: RuntimeEngineEmpty = try await shippedClient.sendMessage(
            name: RuntimeEngine.LoadImageCommand.commandName,
            request: ShippedLoadImageRequest(path: application.framework("Bar").binaryPath),
            timeout: 30
        )
    }

    @Test("Without the field the request and a successful reply encode exactly as before")
    func encodingWithoutTheFieldIsUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        #expect(try encoder.encode(RuntimeEngine.LoadImageCommand(path: "/A/Foo")) == encoder.encode(ShippedLoadImageRequest(path: "/A/Foo")))
        #expect(try encoder.encode(RuntimeImageLoadResponse()) == encoder.encode(RuntimeEngineEmpty()))
        let request = try JSONDecoder().decode(ShippedLoadImageRequest.self, from: encoder.encode(RuntimeEngine.LoadImageCommand(path: "/A/Foo", reportsFailureDiagnosis: true)))
        #expect(request.path == "/A/Foo")
        let response = try JSONDecoder().decode(RuntimeImageLoadResponse.self, from: encoder.encode(RuntimeEngineEmpty()))
        #expect(response.failure == nil)
    }

    #if canImport(SwiftyXPC)
    // A Mach service connection encodes with SwiftyXPC rather than JSON, and an
    // injected payload of an earlier release answers through one.

    @Test("Over a Mach service, a server that predates the field reads the request, and both replies read either way")
    func machServiceEncodingSkipsTheField() throws {
        let request = try XPCDecoder().decode(
            type: ShippedLoadImageRequest.self,
            from: XPCEncoder().encode(RuntimeEngine.LoadImageCommand(path: "/A/Foo", reportsFailureDiagnosis: true))
        )
        #expect(request.path == "/A/Foo")

        let shippedReply = try XPCDecoder().decode(type: RuntimeImageLoadResponse.self, from: XPCEncoder().encode(RuntimeEngineEmpty()))
        #expect(shippedReply.failure == nil)
        _ = try XPCDecoder().decode(type: RuntimeEngineEmpty.self, from: XPCEncoder().encode(RuntimeImageLoadResponse()))

        let failure = RuntimeImageLoadError(dyldMessage: "dlopen(/A/Foo, 0x0001): tried: '/A/Foo' (no such file)", diagnosis: RuntimeImageLoadDiagnosis(dyldMessage: "dlopen(/A/Foo, 0x0001): tried: '/A/Foo' (no such file)", imagePath: "/A/Foo"))
        let roundTripped = try XPCDecoder().decode(type: RuntimeImageLoadResponse.self, from: XPCEncoder().encode(RuntimeImageLoadResponse(failure: failure)))
        #expect(roundTripped.failure == failure)
    }
    #endif

    // MARK: - Asking again

    @Test("Asking again with a host app is answered by the serving process")
    func diagnoseImageLoadIsAnsweredByTheServingProcess() async throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar", placement: .outside("Elsewhere")),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths, placement: .outside("Loose")),
        ])
        let foo = application.framework("Foo")
        let label = "load-failure-diagnosis.ask-again"
        let serving = try await RemoteEnginePair.makeServingEngine(label: label, loading: [])
        let pair = try await RemoteEnginePair.make(.xpcService, label: label, serving: serving)
        defer {
            Task {
                await pair.stop()
                await serving.stop()
            }
        }
        let error = await #expect(throws: RuntimeImageLoadError.self) {
            try await pair.client.loadImageInServingProcess(at: foo.binaryPath)
        }
        let failure = try #require(error)
        #expect(failure.diagnosis?.remedy == nil)

        let searchPath = try #require(application.outsideDirectories["Elsewhere"])
        let diagnosis = try await pair.client.diagnoseImageLoad(at: foo.binaryPath, dyldMessage: failure.dyldMessage, searchPaths: [searchPath])

        #expect(diagnosis.remedy?.imagePathsToLoadFirst.map(Self.canonical) == [Self.canonical(application.framework("Bar").binaryPath)])
    }

    @Test("Asking again is refused, without asking, by an engine whose serving process may be of an earlier version")
    func diagnoseImageLoadIsNotSentToOtherEngines() async throws {
        let engine = RuntimeEngine(
            source: .directTCP(name: "load-failure-diagnosis.unasked", host: "127.0.0.1", port: 1, role: .client),
            engineID: "load-failure-diagnosis.unasked"
        )

        #expect(!engine.diagnosesImageLoadsOnRequest)
        let error = await #expect(throws: RuntimeNetworkRequestError.self) {
            _ = try await engine.diagnoseImageLoad(at: "/A/Foo", dyldMessage: "")
        }
        #expect(error?.isUnknownCommand == true)
    }

    // MARK: - Support

    private static func expectDiagnosis(
        in error: RuntimeImageLoadError?,
        of application: ImageLoadFixtures.HostApplication,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let error else {
            Issue.record("no RuntimeImageLoadError", sourceLocation: sourceLocation)
            return
        }
        #expect(error.dyldMessage.contains("Library not loaded: \(application.framework("Bar").installName)"), sourceLocation: sourceLocation)
        #expect(error.localizedDescription == error.dyldMessage, sourceLocation: sourceLocation)
        guard let diagnosis = error.diagnosis else {
            Issue.record("the failure carries no diagnosis", sourceLocation: sourceLocation)
            return
        }
        #expect(!diagnosis.isFromMessageOnly, sourceLocation: sourceLocation)
        #expect(diagnosis.failure.kind == .imageNotFound, sourceLocation: sourceLocation)
        #expect(diagnosis.dependencyChain.last?.installName == application.framework("Bar").installName, sourceLocation: sourceLocation)
        #expect(diagnosis.remedy?.hostApplicationPath == application.applicationPath, sourceLocation: sourceLocation)
        #expect(diagnosis.remedy?.imagePathsToLoadFirst.map(canonical) == [canonical(application.framework("Bar").binaryPath)], sourceLocation: sourceLocation)
    }

    private static func waitUntilConnected(_ connection: some RuntimeConnection, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while connection.state != .connected {
            guard ContinuousClock.now < deadline else { throw RemoteEngineFixtureTimeout(what: "the serving connection") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

#endif
