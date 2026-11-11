import Foundation

/// What the engine asks an image's Swift section.
protocol RuntimeSwiftSectioning: Actor {
    nonisolated var imagePath: String { get }

    func allObjects() async throws -> [RuntimeObject]

    func interface(for object: RuntimeObject) async throws -> RuntimeObjectInterface

    /// An Objective-C object of this image as Swift imports it; `nil` when the image does not
    /// define it.
    func importedInterface(for object: RuntimeObject) async throws -> RuntimeObjectInterface?

    func updateConfiguration(using options: SwiftGenerationOptions, transformer: Transformer.SwiftConfiguration, marksCommentStructure: Bool, marksAttachedMacros: Bool) async throws

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
