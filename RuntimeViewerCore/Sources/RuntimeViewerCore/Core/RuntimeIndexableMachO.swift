import Foundation
import MachOKit
import MachOObjCSection
import MachOSwiftSection
import ObjCIndexing
import ObjCMetadataSource
import Demangling
@_spi(Support) import SwiftDeclaration
@_spi(Support) import SwiftDeclarationRendering
@_spi(Support) import SwiftIndexing
@_spi(Support) import SwiftSpecialization
@_spi(Support) import SwiftPrivateDiscriminators
@_spi(Internals) import SwiftInspection

/// The ways an engine reads an image: from what dyld mapped into this process
/// (`MachOImage`), or from a file on disk (`MachOFile`).
///
/// The sections, their indexers, the factories and the relationship resolvers
/// are generic over this, and everything that differs between the two ways of
/// reading is a requirement here — so the generic code never asks which one it
/// holds. Today that is three things: what a Swift class's superclass chain is
/// read from, where an Objective-C class keeps its name, and how a generic type
/// is specialized (by instantiating metadata in this process, or statically).
protocol RuntimeIndexableMachO: MachOFieldLayoutRenderable, ObjCMetadataSource, Sendable {
    /// The names of a Swift class and of its superclasses, the class itself
    /// first — what `RuntimeEngine.hierarchy(for:)` answers for a Swift class.
    ///
    /// `aggregate` is the factory's aggregate indexer, which spans every image
    /// indexed so far: a reader that cannot run the class's metadata accessor
    /// walks the superclass names recorded there.
    static func classHierarchy(
        of classDescriptor: ClassDescriptor,
        mangledTypeName: String,
        in machO: Self,
        across aggregate: RuntimeSwiftInterfaceIndexer<Self>
    ) throws -> [String]

    /// The name in an Objective-C class's read-only data.
    static func objcRuntimeName(of objcClass: ObjCClass64, in machO: Self) -> String?

    /// The runtime name and flags of every Objective-C protocol record the
    /// image lists. MachOObjCSection reads a record's name through an overload
    /// per way of reading, so generic code cannot ask for it directly.
    static func objcProtocolRecords(in machO: Self) -> [(name: String, flags: UInt32)]

    /// The index that recovers the source files of the image's private
    /// discriminators. MachOSwiftSection builds it through an initializer per
    /// way of reading.
    static func makePrivateDiscriminatorSourceFileIndex(indexer: SwiftDeclarationIndexer<Self>) -> PrivateDiscriminatorSourceFileIndex

    /// Checks `selection` against the requirements of the type `request` names,
    /// with the evidence this way of reading has.
    static func preflight(
        _ selection: SpecializationSelection,
        for request: SpecializationRequest,
        using specializer: GenericSpecializer<Self>
    ) -> SpecializationValidation

    /// Specializes the type `request` names with `selection`, derives its
    /// nested types, and appends the result to `typeDefinition`'s specialized
    /// children. `typeArgumentNodes` lists the arguments' type nodes in the
    /// order of `request.parameters`, or is `nil` when one is missing.
    ///
    /// Throws what `GenericSpecializer` throws; the caller translates its
    /// `SpecializerError`.
    static func specialize(
        _ typeDefinition: TypeDefinition,
        request: SpecializationRequest,
        selection: SpecializationSelection,
        typeArgumentNodes: [Node]?,
        typeArgumentNodesByParameter: [String: Node],
        using specializer: GenericSpecializer<Self>,
        in machO: Self
    ) async throws -> TypeDefinition
}

// MARK: - Images in this process

extension MachOImage: RuntimeIndexableMachO {
    /// Instantiates the class's metadata and follows its superclass pointers,
    /// Objective-C ancestors included. A generic class has no metadata to
    /// instantiate without arguments, and answers with nothing.
    static func classHierarchy(
        of classDescriptor: ClassDescriptor,
        mangledTypeName: String,
        in machO: MachOImage,
        across aggregate: RuntimeSwiftInterfaceIndexer<MachOImage>
    ) throws -> [String] {
        try ClassHierarchyDumper(machO: machO).dump(for: classDescriptor)
    }

    /// Once the runtime has realized a class — as it has most classes of an
    /// image in use — its data pointer leads to `class_rw_t` instead, which
    /// holds the read-only data either directly or through its extension.
    static func objcRuntimeName(of objcClass: ObjCClass64, in machO: MachOImage) -> String? {
        if let readOnlyData = objcClass.classROData(in: machO) {
            return readOnlyData.name(in: machO)
        }
        guard let readWriteData = objcClass.classRWData(in: machO) else { return nil }
        if let readOnlyData = readWriteData.classROData(in: machO) {
            return readOnlyData.name(in: machO)
        }
        return readWriteData.ext(in: machO)?.classROData(in: machO)?.name(in: machO)
    }

    static func objcProtocolRecords(in machO: MachOImage) -> [(name: String, flags: UInt32)] {
        var records: [(name: String, flags: UInt32)] = []
        for objcProtocol in machO.objc.protocols64 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        for objcProtocol in machO.objc.protocols32 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        return records
    }

    static func makePrivateDiscriminatorSourceFileIndex(indexer: SwiftDeclarationIndexer<MachOImage>) -> PrivateDiscriminatorSourceFileIndex {
        PrivateDiscriminatorSourceFileIndex(indexer: indexer)
    }

    static func preflight(
        _ selection: SpecializationSelection,
        for request: SpecializationRequest,
        using specializer: GenericSpecializer<MachOImage>
    ) -> SpecializationValidation {
        specializer.runtimePreflight(selection: selection, for: request)
    }

    /// Instantiates the specialized metadata through the type's accessor and
    /// rewrites the definition's name from the argument nodes.
    static func specialize(
        _ typeDefinition: TypeDefinition,
        request: SpecializationRequest,
        selection: SpecializationSelection,
        typeArgumentNodes: [Node]?,
        typeArgumentNodesByParameter: [String: Node],
        using specializer: GenericSpecializer<MachOImage>,
        in machO: MachOImage
    ) async throws -> TypeDefinition {
        let result = try specializer.specialize(request, with: selection)
        return try await typeDefinition.specialize(
            with: result,
            typeArgumentNodes: typeArgumentNodes,
            derivingNestedSpecializationsWith: specializer,
            selection: selection,
            typeArgumentNodesByParameter: typeArgumentNodesByParameter,
            in: machO,
        )
    }
}
