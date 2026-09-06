import Foundation
import Testing
@testable import RuntimeViewerCommandLineInterface

/// Every command and result must survive the wire, and the selector's textual
/// form must be the one users type.
@Suite("Protocol coding")
struct ProtocolCodingTests {
    static let sampleTypeInfo = TypeInfo(name: "NSObject", displayName: "NSObject", kind: "Objective-C Class", imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A")

    static let sampleCommands: [Command] = [
        .listImages(ListImagesCommand(source: .local, loadedOnly: true, query: "objc")),
        .loadImage(LoadImageCommand(imagePath: "/usr/lib/libobjc.A.dylib")),
        .listTypes(ListTypesCommand(image: "libobjc.A", kinds: [.objcClass, .swiftStruct])),
        .searchTypes(SearchTypesCommand(image: nil, query: "^NS", isRegularExpression: true)),
        .interface(InterfaceCommand(source: .macCatalyst, image: "AppKit", typeName: "NSView", options: .full)),
        .hierarchy(HierarchyCommand(typeName: "NSView")),
        .relationships(RelationshipsCommand(typeName: "NSCoding")),
        .memberAddresses(MemberAddressesCommand(typeName: "NSObject", memberName: "init")),
        .specialize(SpecializeCommand(source: .attachedProcess(processIdentifier: 42), image: "Foo", typeName: "Box", arguments: ["Element": "Int"], listOnly: false, options: .application)),
        .export(ExportCommand(source: .engine(identifier: "abc"), image: "libobjc.A", outputDirectory: "/tmp/out", objcLayout: .directory, swiftLayout: .single, includeMetadata: false)),
        .listSources(ListSourcesCommand(waitSeconds: 5)),
        .attach(AttachCommand(target: .processIdentifier(550))),
        .attach(AttachCommand(target: .processName("Finder"))),
        .detach(DetachCommand(source: .attachedProcess(processIdentifier: 550))),
        .hostStatus,
        .shutdownHost(.applicationTakeover),
    ]

    static let sampleResults: [CommandResult] = [
        .imageList(ImageListResult(images: [ImageInfo(path: "/usr/lib/libobjc.A.dylib", name: "libobjc.A", isLoaded: true)])),
        .imageLoaded(LoadImageResult(imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A", objectCount: 12, wasAlreadyLoaded: true)),
        .typeList(TypeListResult(imagePaths: ["/usr/lib/libobjc.A.dylib"], types: [sampleTypeInfo])),
        .interface(InterfaceResult(typeInfo: sampleTypeInfo, interfaceText: "@interface NSObject\n@end\n")),
        .hierarchy(HierarchyResult(typeInfo: sampleTypeInfo, hierarchy: ["NSObject"])),
        .relationships(RelationshipsResult(typeInfo: sampleTypeInfo, subclasses: [sampleTypeInfo], conformingTypes: [])),
        .memberAddresses(MemberAddressesResult(typeInfo: sampleTypeInfo, members: [MemberAddress(name: "init", kind: "Method", symbolName: "-[NSObject init]", address: "0x1")])),
        .specializationParameters(SpecializationParametersResult(typeInfo: sampleTypeInfo, parameters: [SpecializationParameter(name: "Element", displayDescription: "Element", candidates: [SpecializationCandidate(displayName: "Int", imagePath: "/usr/lib/swift/libswiftCore.dylib", imageName: "libswiftCore", kind: "struct", isGeneric: false)])])),
        .specialized(SpecializedInterfaceResult(typeInfo: sampleTypeInfo, interfaceText: "struct Box<Int> {}", warnings: ["layout"])),
        .export(ExportResult(imagePath: "/usr/lib/libobjc.A.dylib", imageName: "libobjc.A", outputDirectory: "/tmp/out", succeeded: 10, failed: 1, objcCount: 10, swiftCount: 0, totalDuration: 1.5)),
        .sources(SourcesResult(hosts: [
            SourceHost(hostIdentifier: "host.local", hostName: "This Mac", sources: [
                SourceInfo(engineIdentifier: "engine.local", displayName: "My Mac", kind: .local, selector: .local, stableIdentity: "local", isConnected: true),
                SourceInfo(engineIdentifier: "engine.finder", displayName: "Finder", kind: .attachedXPC, selector: .attachedProcess(processIdentifier: 550), stableIdentity: nil, isConnected: false),
            ]),
            SourceHost(hostIdentifier: "host.phone", hostName: "iPhone", sources: [
                SourceInfo(engineIdentifier: "engine.springboard", displayName: "SpringBoard", kind: .bonjour, selector: .engine(identifier: "engine.springboard"), stableIdentity: "device-1/SpringBoard", isConnected: true),
            ]),
        ])),
        .attached(AttachResult(processName: "Finder", processIdentifier: 550, transport: "xpc", payloadPlatform: "macOS", selector: .attachedProcess(processIdentifier: 550), engineIdentifier: "engine.finder", wasAlreadyAttached: false)),
        .detached(DetachResult(selector: .attachedProcess(processIdentifier: 550), engineIdentifier: "engine.finder", displayName: "Finder", kind: .attachedXPC)),
        .hostStatus(HostStatusResult(processIdentifier: 1, kind: .standalone, version: "0.2.0", protocolVersion: 2, startedAt: Date(timeIntervalSince1970: 1_700_000_000), activeConnections: 1, inFlightCommands: 0, idleTimeout: 600, isShuttingDown: false, loadedImagePaths: [])),
        .shutdownAcknowledged(ShutdownAcknowledgement(reason: .userRequest, processIdentifier: 1)),
    ]

    @Test("Every command round-trips through the wire", arguments: sampleCommands)
    func commandRoundTrip(command: Command) throws {
        let frame = try WireCoding.encodeFrame(ClientMessage.command(requestIdentifier: UUID(), command: command))
        var decoder = FrameCodec.Decoder()
        decoder.append(frame)
        let payload = try #require(try decoder.nextPayload())
        let decoded = try WireCoding.decode(ClientMessage.self, from: payload)
        guard case .command(_, let decodedCommand) = decoded else {
            Issue.record("Decoded a different message: \(decoded)")
            return
        }
        #expect(decodedCommand == command)
    }

    @Test("Every result round-trips through the wire", arguments: sampleResults)
    func resultRoundTrip(result: CommandResult) throws {
        let frame = try WireCoding.encodeFrame(HostMessage.completed(requestIdentifier: UUID(), result: result))
        var decoder = FrameCodec.Decoder()
        decoder.append(frame)
        let payload = try #require(try decoder.nextPayload())
        let decoded = try WireCoding.decode(HostMessage.self, from: payload)
        guard case .completed(_, let decodedResult) = decoded else {
            Issue.record("Decoded a different message: \(decoded)")
            return
        }
        #expect(decodedResult == result)
    }

    @Test("A failure round-trips with its code")
    func failureRoundTrip() throws {
        let failure = CommandFailure(code: .typeNotFound, message: "No type named 'Foo'.")
        let data = try WireCoding.makeEncoder().encode(HostMessage.failed(requestIdentifier: UUID(), failure: failure))
        let decoded = try WireCoding.decode(HostMessage.self, from: data)
        guard case .failed(_, let decodedFailure) = decoded else {
            Issue.record("Decoded a different message: \(decoded)")
            return
        }
        #expect(decodedFailure == failure)
    }

    @Test("Hello and welcome carry the protocol version")
    func handshakeMessages() throws {
        let hello = Hello()
        #expect(hello.protocolVersion == CommandLineProtocol.version)
        // The source commands are new in 2; a version 1 host would drop them.
        #expect(CommandLineProtocol.version == 2)
        let welcome = Welcome(hostKind: .application, processIdentifier: 7)
        let data = try WireCoding.makeEncoder().encode(HostMessage.welcome(welcome))
        let decoded = try WireCoding.decode(HostMessage.self, from: data)
        #expect(decoded == .welcome(welcome))
    }

    @Test("Source selectors parse from and print to their textual form", arguments: [
        ("local", SourceSelector.local),
        ("catalyst", .macCatalyst),
        ("pid:1234", .attachedProcess(processIdentifier: 1234)),
        ("process:Finder", .attachedProcessNamed("Finder")),
        ("engine:ABC-123", .engine(identifier: "ABC-123")),
    ] as [(String, SourceSelector)])
    func sourceSelectorText(text: String, selector: SourceSelector) throws {
        #expect(SourceSelector(text) == selector)
        #expect(selector.description == text)
        let encoded = try JSONEncoder().encode([selector])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"\(text)\"]")
        #expect(try JSONDecoder().decode([SourceSelector].self, from: encoded) == [selector])
    }

    @Test("Malformed selectors are rejected", arguments: ["", "pid:", "pid:abc", "bogus", "process:", "engine:"])
    func malformedSelectors(text: String) {
        #expect(SourceSelector(text) == nil)
    }

    @Test("JSON output is the result payload, not the enum wrapper")
    func jsonOutputIsPayload() throws {
        let rendered = try JSONRenderer.render(CommandResult.interface(InterfaceResult(typeInfo: Self.sampleTypeInfo, interfaceText: "@interface NSObject\n@end")))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        #expect(object["interfaceText"] as? String == "@interface NSObject\n@end")
        let typeInfo = try #require(object["typeInfo"] as? [String: Any])
        #expect(typeInfo["name"] as? String == "NSObject")
        #expect(object["interface"] == nil)
    }

    @Test("Source information encodes its selector as the string the user types")
    func sourceInfoSelectorIsAString() throws {
        let rendered = try JSONRenderer.render(CommandResult.sources(SourcesResult(hosts: [
            SourceHost(hostIdentifier: "host.local", hostName: "This Mac", sources: [
                SourceInfo(engineIdentifier: "engine.finder", displayName: "Finder", kind: .attachedXPC, selector: .attachedProcess(processIdentifier: 550), stableIdentity: nil, isConnected: true),
            ]),
        ])))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        let hosts = try #require(object["hosts"] as? [[String: Any]])
        let sources = try #require(hosts.first?["sources"] as? [[String: Any]])
        #expect(sources.first?["selector"] as? String == "pid:550")
        #expect(sources.first?["kind"] as? String == "attachedXPC")
    }

    @Test("Failures print as an error document under --json")
    func jsonFailureDocument() throws {
        let rendered = JSONRenderer.render(CommandFailure(code: .imageNotFound, message: "gone"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "imageNotFound")
        #expect(error["message"] as? String == "gone")
    }
}

@Suite("Frame codec")
struct FrameCodecTests {
    @Test("A frame split across arbitrary chunk boundaries decodes once complete")
    func partialFrames() throws {
        let payload = Data("hello, host".utf8)
        let frame = try FrameCodec.encodeFrame(payload: payload)
        var decoder = FrameCodec.Decoder()
        for byte in frame.dropLast() {
            decoder.append(Data([byte]))
            #expect(try decoder.nextPayload() == nil)
        }
        decoder.append(Data([frame.last!]))
        #expect(try decoder.nextPayload() == payload)
        #expect(try decoder.nextPayload() == nil)
        #expect(decoder.pendingByteCount == 0)
    }

    @Test("Several frames in one chunk decode in order")
    func coalescedFrames() throws {
        let payloads = ["one", "two", "three"].map { Data($0.utf8) }
        var chunk = Data()
        for payload in payloads {
            chunk.append(try FrameCodec.encodeFrame(payload: payload))
        }
        var decoder = FrameCodec.Decoder()
        decoder.append(chunk)
        var decoded: [Data] = []
        while let payload = try decoder.nextPayload() {
            decoded.append(payload)
        }
        #expect(decoded == payloads)
    }

    @Test("An empty payload is a valid frame")
    func emptyPayload() throws {
        var decoder = FrameCodec.Decoder()
        decoder.append(try FrameCodec.encodeFrame(payload: Data()))
        #expect(try decoder.nextPayload() == Data())
    }

    @Test("An absurd length field is rejected instead of allocated")
    func oversizedLength() {
        var decoder = FrameCodec.Decoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: FrameCodec.FrameError.payloadTooLarge(Int(UInt32.max))) {
            try decoder.nextPayload()
        }
    }
}
