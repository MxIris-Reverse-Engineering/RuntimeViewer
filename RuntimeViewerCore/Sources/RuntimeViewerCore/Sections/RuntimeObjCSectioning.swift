import Foundation

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

    func allObjects() async throws -> [RuntimeObject]

    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration, marksCommentStructure: Bool) async throws -> RuntimeObjectInterface

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress]

    func makeRuntimeObject(forClassName className: String) -> RuntimeObject?

    func makeRuntimeObject(forProtocolName protocolName: String) -> RuntimeObject?

    func classHierarchy(for object: RuntimeObject) async throws -> [String]

    nonisolated func corpusPrint(for object: RuntimeObject, transformer: Transformer.Configuration) async throws -> RuntimeInterfaceCorpusPrint?
}
