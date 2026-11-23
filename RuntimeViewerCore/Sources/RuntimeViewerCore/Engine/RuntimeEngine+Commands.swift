import Foundation
import RuntimeViewerCommunication

// MARK: - Image queries

extension RuntimeEngine {
    struct IsImageLoadedCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.isImageLoaded.commandName }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._isImageLoaded(path: path)
        }
    }

    struct IsImageIndexedCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.isImageIndexed.commandName }
        var subjectImagePath: String? { path }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._isImageIndexed(path: path)
        }
    }

    struct MainExecutablePathCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.mainExecutablePath.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String {
            engine.imageCatalog.mainExecutablePath()
        }
    }

    struct LoadImageCommand: RuntimeEngineCommand {
        let path: String
        /// Set by a requester that reads a refused load from the reply: the
        /// serving process then answers a `DyldOpenError` with a
        /// `RuntimeImageLoadResponse` whose `failure` carries its diagnosis,
        /// instead of failing the request. A peer of an earlier version skips
        /// the key and fails with dyld's message, which is all such a
        /// requester then gets. Never set, the reply is the empty object it
        /// always was (`CommunicationAndEngineArchitecture.md` §4.4).
        var reportsFailureDiagnosis: Bool?

        init(path: String, reportsFailureDiagnosis: Bool? = nil) {
            self.path = path
            self.reportsFailureDiagnosis = reportsFailureDiagnosis
        }

        static var commandName: String { CommandName.loadImage.commandName }
        var subjectImagePath: String? { path }
        static var isForegroundLoad: Bool { true }
        static var indexesSubjectImage: Bool { true }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeImageLoadResponse {
            do {
                try await engine._loadImage(at: path)
                return RuntimeImageLoadResponse()
            } catch let error as DyldOpenError where reportsFailureDiagnosis == true {
                let imagePath = engine.imageCatalog.canonicalImagePath(path)
                return RuntimeImageLoadResponse(failure: engine.diagnosedLoadFailure(error, forImageAt: imagePath))
            }
        }
    }

    /// Retraces a refused load with a host app or more search paths, to find
    /// what to load first. Answered by the process that tried the load — its
    /// dependencies and rpaths are its own, which no shared cache owner can
    /// answer for, so `subjectImagePath` stays `nil`. Sent only where
    /// `RuntimeEngine.diagnosesImageLoadsOnRequest` holds.
    struct DiagnoseImageLoadCommand: RuntimeEngineCommand {
        let imagePath: String
        let dyldMessage: String
        let hostApplicationPath: String?
        let searchPaths: [String]
        static var commandName: String { CommandName.diagnoseImageLoad.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeImageLoadDiagnosis {
            RuntimeImageLoadDiagnostician(environment: .currentProcess()).diagnose(
                imageAt: engine.imageCatalog.canonicalImagePath(imagePath),
                dyldMessage: dyldMessage,
                hostApplicationPath: hostApplicationPath,
                searchPaths: searchPaths
            )
        }
    }

    struct LoadImageWithProgressCommand: RuntimeEngineProgressCommand {
        let path: String
        static var commandName: String { CommandName.loadImageWithProgress.commandName }
        var subjectImagePath: String? { path }
        static var isForegroundLoad: Bool { true }
        static var indexesSubjectImage: Bool { true }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImage(at: path)
            return RuntimeEngineEmpty()
        }

        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> RuntimeEngineEmpty {
            try await engine._loadImage(at: path, reportProgress: reportProgress)
            return RuntimeEngineEmpty()
        }
    }

    struct LoadImageForBackgroundIndexingCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.loadImageForBackgroundIndexing.commandName }
        var subjectImagePath: String? { path }
        static var indexesSubjectImage: Bool { true }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImageForBackgroundIndexing(at: path)
            return RuntimeEngineEmpty()
        }
    }

    /// Where the serving process's SDK type index stands (`RuntimeTypeIndex`).
    /// About the serving process itself: no subject image, so an engine
    /// borrowing shared cache images answers it as the one it was sent to.
    struct TypeIndexStatusCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.typeIndexStatus.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeTypeIndexStatus {
            await engine.localTypeIndexStatus()
        }
    }

    struct ReloadDataCommand: RuntimeEngineCommand {
        let isReloadImageNodes: Bool
        static var commandName: String { CommandName.reloadData.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            await engine.reloadLocalData(isReloadImageNodes: isReloadImageNodes)
            return RuntimeEngineEmpty()
        }
    }

    /// Server-side answer to `imageName(ofObjectName:)`: the image the
    /// serving process's runtime finds an Objective-C class or protocol in.
    /// Its local arm answered `nil` until engines started borrowing shared
    /// cache images, so a peer of an earlier release still does — which an
    /// asker takes for "not known".
    struct ImageNameOfObjectCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.imageNameOfClassName.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String? {
            await engine._imageName(ofObjectName: object)
        }
    }

    /// Resolves Mach-O / bundle metadata for the inspected image on the engine
    /// that actually owns the image, so export README metadata is not polluted
    /// by the macOS host process picking up a same-named framework via
    /// `DyldUtilities`' basename fallback.
    struct ExportModuleInfoCommand: RuntimeEngineCommand {
        let imagePath: String
        let imageName: String
        static var commandName: String { CommandName.runtimeInterfaceExportModuleInfo.commandName }
        var subjectImagePath: String? { imagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeInterfaceExportMetadata.ModuleInfo {
            RuntimeInterfaceExportMetadata.ModuleInfo.resolve(imagePath: imagePath, imageName: imageName)
        }
    }
}

// MARK: - Objects & interfaces

extension RuntimeEngine {
    struct ObjectsInImageCommand: RuntimeEngineProgressCommand {
        let image: String
        /// Whether the reply may carry the image's C++ objects. Left out of
        /// the encoding unless it is true, so the request of a caller that
        /// does not want them — and of a build before C++ objects — is byte
        /// for byte what it was, and the reply has no kind such a build cannot
        /// decode. A peer of such a build skips the key and answers
        /// Objective-C and Swift objects only. A field rather than a command
        /// of its own: an injected payload of an earlier release drops the
        /// connection on a command it does not know (PR121.73).
        let includesCPlusPlusObjects: Bool?
        static var commandName: String { CommandName.runtimeObjectsInImage.commandName }
        var subjectImagePath: String? { image }
        static var isForegroundLoad: Bool { true }
        static var indexesSubjectImage: Bool { true }

        init(image: String, includesCPlusPlusObjects: Bool = false) {
            self.image = image
            self.includesCPlusPlusObjects = includesCPlusPlusObjects ? true : nil
        }

        func perform(on engine: RuntimeEngine) async throws -> [RuntimeObject] {
            try await engine._objects(in: image, includesCPlusPlusObjects: includesCPlusPlusObjects == true)
        }

        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> [RuntimeObject] {
            try await engine._objects(in: image, includesCPlusPlusObjects: includesCPlusPlusObjects == true, reportProgress: reportProgress)
        }
    }

    struct InterfaceCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let options: RuntimeObjectInterface.GenerationOptions
        /// `true` from builds that read `interfaceString` in the columnar
        /// `FrozenSemanticString` encoding. Builds up to 3.0.0-beta.6 send no
        /// such key, so their requests decode it as `nil`, and skip it when
        /// they decode a request of this build; either way they are answered
        /// in the component array they read. See `RuntimeObjectInterfaceResponse`.
        let acceptsColumnarInterfaceString: Bool?
        /// `false` keeps the answer to the object's own image: no lookup of a
        /// reference across the other indexed images or through the runtime.
        /// An engine that borrows shared cache images asks this way first, so
        /// that a reference to a shared cache type is not indexed in its
        /// serving process. Optional on the wire, like the field above: `nil`
        /// — every earlier sender — looks references up.
        var resolvesReferencesAcrossImages: Bool? = nil
        static var commandName: String { CommandName.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObjectInterfaceResponse {
            try await response(for: engine._interface(for: object, options: options, resolvesReferencesAcrossImages: resolvesReferencesAcrossImages ?? true))
        }

        /// The reply, in the encoding the sender of this request reads.
        func response(for interface: RuntimeObjectInterface?) -> RuntimeObjectInterfaceResponse {
            RuntimeObjectInterfaceResponse(
                interface: interface,
                interfaceStringEncoding: acceptsColumnarInterfaceString == true ? .columnar : .components
            )
        }
    }

    struct HierarchyCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.runtimeObjectHierarchy.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            try await engine._hierarchy(for: object)
        }
    }

    struct SuperclassChainCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.runtimeObjectSuperclassChain.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeRelationshipNode] {
            try await engine._superclassChain(for: object)
        }
    }

    struct RefinedProtocolTreeCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.runtimeObjectRefinedProtocolTree.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeRelationshipNode] {
            try await engine._refinedProtocolTree(for: object)
        }
    }

    struct RelationshipsCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.runtimeRelationshipsForObject.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeRelationships {
            await engine._relationships(for: object)
        }
    }

    struct CounterpartCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.runtimeCounterpartForObject.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObject? {
            await engine._counterpart(for: object)
        }
    }

    struct MemberAddressesCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let memberName: String?
        static var commandName: String { CommandName.memberAddresses.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeMemberAddress] {
            try await engine._memberAddresses(for: object, memberName: memberName)
        }
    }

    struct PrivateDeclarationSourceFilesCommand: RuntimeEngineCommand {
        let discriminators: [String]
        let imagePath: String
        static var commandName: String { CommandName.privateDeclarationSourceFiles.commandName }
        var subjectImagePath: String? { imagePath }
        func perform(on engine: RuntimeEngine) async throws -> [String: RuntimePrivateDeclarationSourceFile] {
            await engine._privateDeclarationSourceFiles(forDiscriminators: discriminators, inImage: imagePath)
        }
    }
}

// MARK: - Generic specialization

extension RuntimeEngine {
    /// Wire form of `specializationRequest(for:)`. The `for object:` half is in
    /// `RuntimeEngine+GenericSpecialization.swift` so the public API and its
    /// `RuntimeEngineCommand` shim stay co-located.
    struct SpecializationRequestForObjectCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.specializationRequest.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(for: object)
        }
    }

    struct SpecializationRequestForCandidateCommand: RuntimeEngineCommand {
        let candidateID: String
        let imagePath: String
        static var commandName: String { CommandName.specializationRequestForCandidate.commandName }
        var subjectImagePath: String? { imagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(forCandidateID: candidateID, in: imagePath)
        }
    }

    struct RuntimePreflightCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandName.runtimePreflight.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationValidation {
            try await engine._runtimePreflight(for: object, with: selection)
        }
    }

    struct SpecializeCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandName.specialize.commandName }
        var subjectImagePath: String? { object.subjectImagePath }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObject {
            try await engine._specialize(object, with: selection)
        }
    }
}

// MARK: - Subject images

private extension RuntimeObject {
    /// The image a request about this object is about. A reference the engine
    /// built from a name alone carries an empty path and names no image, so
    /// it stays with the engine it was sent to, which looks the name up.
    var subjectImagePath: String? {
        imagePath.isEmpty ? nil : imagePath
    }
}
