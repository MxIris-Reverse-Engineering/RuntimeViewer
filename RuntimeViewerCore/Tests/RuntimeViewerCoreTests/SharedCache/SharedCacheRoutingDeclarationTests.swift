import Foundation
import Testing
import Combine
import RuntimeViewerCommunication
@testable import RuntimeViewerCore

/// Every built-in command says how an engine that borrows shared cache images
/// routes it: to the owner of the one image it is about, or to the engine it
/// was sent to. A command added without saying so fails here, instead of
/// being answered by the wrong process — an attached process indexing a
/// system image again, which is what borrowing exists to stop.
@Suite("Shared cache routing declarations")
struct SharedCacheRoutingDeclarationTests {
    private static let imagePath = "/usr/lib/libobjc.A.dylib"

    private static let object = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: imagePath, children: [])

    /// An object the engine built from a name alone, which names no image.
    private static let referenceObject = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: "", children: [])

    /// Who answers a command for an engine that borrows shared cache images.
    enum Routing: Sendable {
        /// The owner of the image it is about, when it is a borrowed image.
        case subjectImageOwner
        /// The engine and its owners together, each for its own images: a
        /// question about every image the engine has indexed.
        case everyParticipant
        /// The engine it was sent to: a question about its serving process.
        case servingEngine
    }

    struct Declaration: Sendable, CustomTestStringConvertible {
        let commandName: String
        let routing: Routing
        let subjectImagePath: String?
        let spansImages: Bool

        init<Command: RuntimeEngineCommand>(_ command: Command, _ routing: Routing) {
            self.commandName = Command.commandName
            self.routing = routing
            self.subjectImagePath = command.subjectImagePath
            self.spansImages = command is any RuntimeEngineSpanningCommand || command is any RuntimeEngineSpanningProgressCommand
        }

        var testDescription: String {
            commandName
        }
    }

    static let declarations: [Declaration] = [
        // Loaded state follows the serving process; an owner's loads are
        // added by the engine itself.
        Declaration(RuntimeEngine.IsImageLoadedCommand(path: imagePath), .servingEngine),
        Declaration(RuntimeEngine.IsImageIndexedCommand(path: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.MainExecutablePathCommand(), .servingEngine),
        Declaration(RuntimeEngine.LoadImageCommand(path: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.LoadImageWithProgressCommand(path: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.LoadImageForBackgroundIndexingCommand(path: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.ReloadDataCommand(isReloadImageNodes: false), .servingEngine),
        // The dependency walk reads the images the serving process loaded.
        Declaration(RuntimeEngine.CanOpenImageCommand(path: imagePath), .servingEngine),
        Declaration(RuntimeEngine.RpathsCommand(path: imagePath), .servingEngine),
        Declaration(RuntimeEngine.DependenciesCommand(path: imagePath, ancestorRpaths: [], mainExecutablePath: imagePath), .servingEngine),
        Declaration(RuntimeEngine.ImageNameOfObjectCommand(object: object), .servingEngine),
        Declaration(RuntimeEngine.ExportModuleInfoCommand(imagePath: imagePath, imageName: "libobjc"), .subjectImageOwner),
        Declaration(RuntimeEngine.ObjectsInImageCommand(image: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.InterfaceCommand(object: object, options: .init(), acceptsColumnarInterfaceString: true), .subjectImageOwner),
        Declaration(RuntimeEngine.InterfaceCommand(object: referenceObject, options: .init(), acceptsColumnarInterfaceString: true), .servingEngine),
        Declaration(RuntimeEngine.HierarchyCommand(object: object), .subjectImageOwner),
        Declaration(RuntimeEngine.SuperclassChainCommand(object: object), .subjectImageOwner),
        Declaration(RuntimeEngine.RefinedProtocolTreeCommand(object: object), .subjectImageOwner),
        Declaration(RuntimeEngine.RelationshipsCommand(object: object), .everyParticipant),
        Declaration(RuntimeEngine.CounterpartCommand(object: object), .subjectImageOwner),
        Declaration(RuntimeEngine.MemberAddressesCommand(object: object, memberName: nil), .subjectImageOwner),
        Declaration(RuntimeEngine.PrivateDeclarationSourceFilesCommand(discriminators: [], imagePath: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.SpecializationRequestForObjectCommand(object: object), .subjectImageOwner),
        Declaration(RuntimeEngine.SpecializationRequestForCandidateCommand(candidateID: "candidate", imagePath: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.RuntimePreflightCommand(object: object, selection: .init()), .subjectImageOwner),
        Declaration(RuntimeEngine.SpecializeCommand(object: object, selection: .init()), .subjectImageOwner),
        Declaration(RuntimeEngine.BuildInterfaceCorpusCommand(imagePath: imagePath, transformer: .init(), isPrioritized: false), .subjectImageOwner),
        Declaration(RuntimeEngine.PrioritizeInterfaceCorpusCommand(imagePath: imagePath), .subjectImageOwner),
        Declaration(RuntimeEngine.RestoreInterfaceCorporaCommand(imagePaths: [imagePath], transformer: .init()), .everyParticipant),
        Declaration(RuntimeEngine.SearchInterfacesCommand(query: .init(text: "NSObject")), .everyParticipant),
        Declaration(RuntimeEngine.SearchMembersCommand(query: .init(text: "init")), .everyParticipant),
        Declaration(RuntimeEngine.TypeRelationshipsCommand(query: .init(text: "NSObject", relationship: .descendants)), .everyParticipant),
        Declaration(RuntimeEngine.IndexedImagePathsCommand(), .everyParticipant),
        // Each engine's corpus coverage and budget are its own.
        Declaration(RuntimeEngine.InterfaceCorpusCoverageCommand(), .servingEngine),
        Declaration(RuntimeEngine.EvictInterfaceCorpusCommand(imagePath: imagePath, keepsStoredCorpora: nil), .subjectImageOwner),
        Declaration(RuntimeEngine.EvictInterfaceCorpusCommand(imagePath: nil, keepsStoredCorpora: true), .servingEngine),
        Declaration(RuntimeEngine.SetInterfaceCorpusResidentByteLimitCommand(byteLimit: 0), .servingEngine),
        Declaration(RuntimeEngine.DyldRootPathCommand(), .servingEngine),
    ]

    @Test("Every built-in command declares how it is routed")
    func everyBuiltInCommandIsDeclared() {
        let connection = RecordingConnection()
        let registrar = RuntimeEngineCommandRegistrar(connection: connection, engine: RuntimeEngine(source: .local))

        RuntimeEngine.registerBuiltInHandlers(into: registrar)

        let installedCommandNames = registrar.installedCommandNames.subtracting([RuntimeEngine.CommandName.cancelRequest.commandName])
        #expect(Set(Self.declarations.map(\.commandName)) == installedCommandNames)
    }

    @Test("A command about one image names that image, a command about every image spans the participants, and the rest do neither", arguments: declarations)
    func declarationMatchesTheRouting(declaration: Declaration) {
        switch declaration.routing {
        case .subjectImageOwner:
            #expect(declaration.subjectImagePath == Self.imagePath)
        case .everyParticipant:
            #expect(declaration.subjectImagePath == nil)
            #expect(declaration.spansImages)
        case .servingEngine:
            #expect(declaration.subjectImagePath == nil)
            #expect(!declaration.spansImages)
        }
    }
}

/// A connection that records the wire names handlers were installed under and
/// does nothing else; these tests assemble a command table, they never use
/// one.
private final class RecordingConnection: RuntimeConnection, @unchecked Sendable {
    private struct NotSentHere: Error {}

    let statePublisher = Empty<RuntimeConnectionState, Never>(completeImmediately: false)

    var state: RuntimeConnectionState { .connected }

    func stop() {}

    func sendMessage(name: String) async throws {
        throw NotSentHere()
    }

    func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        throw NotSentHere()
    }

    func sendMessage<Response: Codable>(name: String) async throws -> Response {
        throw NotSentHere()
    }

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        throw NotSentHere()
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        throw NotSentHere()
    }

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {}

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {}

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {}

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) {}

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {}
}
