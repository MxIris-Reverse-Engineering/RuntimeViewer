import Foundation
import ObjCDeclarationRendering

/// What the engine asks an image's Swift section.
protocol RuntimeSwiftSectioning: Actor {
    nonisolated var imagePath: String { get }

    func allObjects() async throws -> [RuntimeObject]

    /// The interface of `object` printed with `options`. Configuring the printer and printing
    /// with it are one step, so a request with other options cannot reconfigure the printer in
    /// the middle of this one's print.
    func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface

    /// An Objective-C object of this image as Swift imports it, printed with `options` as
    /// `interface(for:options:)` prints; `nil` when the image does not define it.
    func importedInterface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface?

    /// What the header of an Objective-C class of this image says about Swift imports, as far as
    /// the image's Swift side shows: `NS_REFINED_FOR_SWIFT` on the members MachOSwiftSection finds
    /// refined. Empty for anything but a class, and for a class no Swift code of the image extends.
    func objcSwiftImportNotes(for object: RuntimeObject) async throws -> ObjCSwiftImportNotes

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
