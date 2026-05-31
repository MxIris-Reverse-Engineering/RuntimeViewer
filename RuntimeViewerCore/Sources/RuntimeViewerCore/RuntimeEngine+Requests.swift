import Foundation
import RuntimeViewerCommunication

// MARK: - Image queries

extension RuntimeEngine {
    struct IsImageLoadedRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.isImageLoaded.commandName }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._isImageLoaded(path: path)
        }
    }

    struct IsImageIndexedRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.isImageIndexed.commandName }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._isImageIndexed(path: path)
        }
    }

    struct MainExecutablePathRequest: RuntimeEngineRequest {
        static var commandName: String { CommandNames.mainExecutablePath.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String {
            DyldUtilities.mainExecutablePath()
        }
    }

    struct LoadImageRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.loadImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImage(at: path)
            return RuntimeEngineEmpty()
        }
    }

    struct LoadImageForBackgroundIndexingRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.loadImageForBackgroundIndexing.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
            try await engine._loadImageForBackgroundIndexing(at: path)
            return RuntimeEngineEmpty()
        }
    }

    /// Server-side answer to `imageName(ofObjectName:)`. Symmetric with the
    /// pre-refactor behavior where the local arm always returned `nil` and
    /// only the remote arm answered meaningfully — so a proxy / server engine
    /// keeps that empty answer when no upstream lookup is available.
    struct ImageNameOfObjectRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        static var commandName: String { CommandNames.imageNameOfClassName.commandName }
        func perform(on engine: RuntimeEngine) async throws -> String? {
            nil
        }
    }
}

// MARK: - Objects & interfaces

extension RuntimeEngine {
    struct ObjectsInImageRequest: RuntimeEngineRequest {
        let image: String
        static var commandName: String { CommandNames.runtimeObjectsInImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeObject] {
            try await engine._objects(in: image)
        }
    }

    struct InterfaceRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        let options: RuntimeObjectInterface.GenerationOptions
        static var commandName: String { CommandNames.runtimeInterfaceForRuntimeObjectInImageWithOptions.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObjectInterface? {
            try await engine._interface(for: object, options: options)
        }
    }

    struct HierarchyRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        static var commandName: String { CommandNames.runtimeObjectHierarchy.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            try await engine._hierarchy(for: object)
        }
    }

    struct RelationshipsRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        static var commandName: String { CommandNames.runtimeRelationshipsForObject.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeRelationships {
            await engine._relationships(for: object)
        }
    }

    struct MemberAddressesRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        let memberName: String?
        static var commandName: String { CommandNames.memberAddresses.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeMemberAddress] {
            try await engine._memberAddresses(for: object, memberName: memberName)
        }
    }
}

// MARK: - Generic specialization

extension RuntimeEngine {
    /// Wire form of `specializationRequest(for:)`. The `for object:` half is in
    /// `RuntimeEngine+GenericSpecialization.swift` so the public API and its
    /// `RuntimeEngineRequest` shim stay co-located.
    struct SpecializationRequestForObjectRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        static var commandName: String { CommandNames.specializationRequest.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(for: object)
        }
    }

    struct SpecializationRequestForCandidateRequest: RuntimeEngineRequest {
        let candidateID: String
        let imagePath: String
        static var commandName: String { CommandNames.specializationRequestForCandidate.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationRequest {
            try await engine._specializationRequest(forCandidateID: candidateID, in: imagePath)
        }
    }

    struct RuntimePreflightRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandNames.runtimePreflight.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeSpecializationValidation {
            try await engine._runtimePreflight(for: object, with: selection)
        }
    }

    struct SpecializeRequest: RuntimeEngineRequest {
        let object: RuntimeObject
        let selection: RuntimeSpecializationSelection
        static var commandName: String { CommandNames.specialize.commandName }
        func perform(on engine: RuntimeEngine) async throws -> RuntimeObject {
            try await engine._specialize(object, with: selection)
        }
    }
}
