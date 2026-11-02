import Foundation

// The sections, their factories and the relationship resolvers are generic
// over the way an image is read (`RuntimeIndexableMachO`). `RuntimeEngine` is
// not: it holds them through the protocols below, which name only
// RuntimeViewer's own types. Each factory protocol says what section it hands
// out as an associated type, so a call through `any` gets that section back
// erased to the section protocol, and the factories keep returning their
// concrete sections to the generic code around them.

/// What the engine asks an image's Objective-C section.
protocol RuntimeObjCSectioning: Actor {
    nonisolated var imagePath: String { get }

    func allObjects() async throws -> [RuntimeObject]

    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration, marksCommentStructure: Bool) async throws -> RuntimeObjectInterface

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress]

    func makeRuntimeObject(forClassName className: String) -> RuntimeObject?

    func makeRuntimeObject(forProtocolName protocolName: String) -> RuntimeObject?

    func classHierarchy(for object: RuntimeObject) async throws -> [String]

    nonisolated func corpusPrint(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusPrint?
}

/// What the engine asks an image's Swift section.
protocol RuntimeSwiftSectioning: Actor {
    nonisolated var imagePath: String { get }

    func allObjects() async throws -> [RuntimeObject]

    func interface(for object: RuntimeObject) async throws -> RuntimeObjectInterface

    func updateConfiguration(using options: SwiftGenerationOptions, transformer: Transformer.SwiftConfiguration, marksCommentStructure: Bool) async throws

    func classHierarchy(for object: RuntimeObject) async throws -> [String]

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress]

    nonisolated func privateDeclarationSourceFiles(forDiscriminators discriminators: [String]) async -> [String: RuntimePrivateDeclarationSourceFile]

    func makeRuntimeObject(forMangledTypeName mangledName: String) -> RuntimeObject?

    func makeRuntimeObject(forMangledProtocolName mangledName: String) -> RuntimeObject?

    func makeRuntimeObject(forObjCRuntimeClassName className: String) -> RuntimeObject?

    func makeRuntimeObject(forObjCImplementationClassNamed className: String) -> RuntimeObject?

    func makeRuntimeObject(forObjCRuntimeProtocolName protocolName: String) -> RuntimeObject?

    func objcClassName(forCounterpartOf object: RuntimeObject) -> String?

    func objcProtocolName(forCounterpartOf object: RuntimeObject) -> String?

    func specializationRequest(for object: RuntimeObject) async throws -> RuntimeSpecializationRequest

    func specializationRequest(forCandidateID candidateID: String, in imagePath: String) async throws -> RuntimeSpecializationRequest

    func specialize(for object: RuntimeObject, with selection: RuntimeSpecializationSelection) async throws -> RuntimeObject

    func runtimePreflight(for object: RuntimeObject, with selection: RuntimeSpecializationSelection) async throws -> RuntimeSpecializationValidation

    nonisolated func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome]
}

/// The per-image Objective-C sections of an engine.
protocol RuntimeObjCSectionProviding: Actor {
    associatedtype Section: RuntimeObjCSectioning

    func existingSection(for imagePath: String) -> Section?

    func hasCachedSection(for path: String) -> Bool

    /// Every image path with a section, under the key it was built for.
    var cachedImagePaths: Set<String> { get }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

    /// The section of the image that defines an Objective-C class or protocol
    /// no image indexed so far was asked about — `nil` when the engine's
    /// catalog knows of none.
    func section(for name: RuntimeObjCName) async throws -> Section?

    func removeAllSections()
}

extension RuntimeObjCSectionProviding {
    func section(for imagePath: String) async throws -> (isExisted: Bool, section: Section) {
        try await section(for: imagePath, progressContinuation: nil)
    }
}

/// The per-image Swift sections of an engine, and the cross-image tables
/// built as they register.
protocol RuntimeSwiftSectionProviding: Actor {
    associatedtype Section: RuntimeSwiftSectioning

    func existingSection(for imagePath: String) -> Section?

    func hasCachedSection(for path: String) -> Bool

    var cachedImagePaths: Set<String> { get }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: Section)

    /// The key of the section defining the nominal type a mangled name names.
    func imagePath(definingTypeWithCandidateID candidateID: String) -> String?

    /// The key of the section defining the protocol a mangled name names.
    func imagePath(definingProtocolWithCandidateID candidateID: String) -> String?

    /// The image that declares the `@objc` protocol an Objective-C protocol
    /// record of `runtimeName` belongs to, among the images indexed right now.
    func imagePath(declaringObjCProtocolNamed runtimeName: String) -> String?

    func removeAllSections()
}

extension RuntimeSwiftSectionProviding {
    func section(for imagePath: String) async throws -> (isExisted: Bool, section: Section) {
        try await section(for: imagePath, progressContinuation: nil)
    }
}

/// The Inspector's Relationships rows.
protocol RuntimeRelationshipsResolving: Actor {
    func relationships(for object: RuntimeObject) async -> RuntimeRelationships
}

/// The Find navigator's relationship trees and the Inspector's hierarchies.
protocol RuntimeTypeRelationshipsResolving: Actor {
    func trees(for query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree]

    func refinedProtocolTree(of object: RuntimeObject) async throws -> [RuntimeRelationshipNode]

    func superclassChain(of object: RuntimeObject) async throws -> [RuntimeRelationshipNode]
}
