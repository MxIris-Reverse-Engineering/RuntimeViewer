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
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._isImageIndexed(path: path)
        }
    }

    struct MainExecutablePathCommand: RuntimeEngineCommand {
        static var commandName: String { CommandName.mainExecutablePath.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String {
            DyldUtilities.mainExecutablePath()
        }
    }

    struct LoadImageCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.loadImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImage(at: path)
            return RuntimeEngineEmpty()
        }
    }

    struct LoadImageWithProgressCommand: RuntimeEngineProgressCommand {
        let path: String
        static var commandName: String { CommandName.loadImageWithProgress.commandName }
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
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImageForBackgroundIndexing(at: path)
            return RuntimeEngineEmpty()
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

    /// Server-side answer to `imageName(ofObjectName:)`. Symmetric with the
    /// pre-refactor behavior where the local arm always returned `nil` and
    /// only the remote arm answered meaningfully — so a proxy / server engine
    /// keeps that empty answer when no upstream lookup is available.
    struct ImageNameOfObjectCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        static var commandName: String { CommandName.imageNameOfClassName.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String? {
            nil
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
        func perform(on engine: RuntimeEngine) async throws -> RuntimeInterfaceExportMetadata.ModuleInfo {
            RuntimeInterfaceExportMetadata.ModuleInfo.resolve(imagePath: imagePath, imageName: imageName)
        }
    }
}

// MARK: - Objects & interfaces

extension RuntimeEngine {
    struct ObjectsInImageCommand: RuntimeEngineProgressCommand {
        let image: String
        static var commandName: String { CommandName.runtimeObjectsInImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeObject] {
            try await engine._objects(in: image)
        }

        func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> [RuntimeObject] {
            try await engine._objects(in: image, reportProgress: reportProgress)
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
        static var commandName: String { CommandName.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObjectInterfaceResponse {
            try await response(for: engine._interface(for: object, options: options))
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
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            try await engine._hierarchy(for: object)
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
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObject? {
            await engine._counterpart(for: object)
        }
    }

    struct MemberAddressesCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let memberName: String?
        static var commandName: String { CommandName.memberAddresses.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeMemberAddress] {
            try await engine._memberAddresses(for: object, memberName: memberName)
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
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(for: object)
        }
    }

    struct SpecializationRequestForCandidateCommand: RuntimeEngineCommand {
        let candidateID: String
        let imagePath: String
        static var commandName: String { CommandName.specializationRequestForCandidate.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(forCandidateID: candidateID, in: imagePath)
        }
    }

    struct RuntimePreflightCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandName.runtimePreflight.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationValidation {
            try await engine._runtimePreflight(for: object, with: selection)
        }
    }

    struct SpecializeCommand: RuntimeEngineCommand {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandName.specialize.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObject {
            try await engine._specialize(object, with: selection)
        }
    }
}
