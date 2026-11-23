import Foundation
import ObjCDeclarationRendering

// The sections, their factories and the relationship resolvers are generic
// over the way an image is read (`RuntimeImageReading`). `RuntimeEngine` is
// not: it holds them through protocols that name only RuntimeViewer's own
// types — this one, `RuntimeSwiftSectioning`, `RuntimeObjCSectionProviding`,
// `RuntimeSwiftSectionProviding`, `RuntimeRelationshipsResolving` and
// `RuntimeTypeRelationshipsResolving`. Each factory protocol says what section
// it hands out as an associated type, so a call through `any` gets that section back
// erased to the section protocol, and the factories keep returning their
// concrete sections to the generic code around them.

/// What the engine asks an image's Objective-C section.
protocol RuntimeObjCSectioning: Actor {
    nonisolated var imagePath: String { get }

    /// The SDK platform the type index reads for this image, by its raw value
    /// (`RuntimeTypeNames.platformName(of:)`); `nil` for an image naming no
    /// platform an SDK covers.
    nonisolated var typeIndexPlatformName: String? { get }

    func allObjects() async throws -> [RuntimeObject]

    /// `swiftImportNotes` are what the image's Swift side shows a class's header to say about
    /// Swift imports (`RuntimeSwiftSectioning.objcSwiftImportNotes(for:)`); empty for anything else.
    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration, marksCommentStructure: Bool, swiftImportNotes: ObjCSwiftImportNotes) async throws -> RuntimeObjectInterface

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress]

    func makeRuntimeObject(forClassName className: String) -> RuntimeObject?

    func makeRuntimeObject(forProtocolName protocolName: String) -> RuntimeObject?

    func classHierarchy(for object: RuntimeObject) async throws -> [String]

    /// `swiftImportNotes` must be the ones `interface(for:using:transformer:marksCommentStructure:swiftImportNotes:)`
    /// is given for the object: Find highlights a result at its place in this print.
    nonisolated func corpusPrint(for object: RuntimeObject, transformer: Transformer.Configuration, swiftImportNotes: ObjCSwiftImportNotes) async throws -> RuntimeInterfaceCorpusPrint?
}
