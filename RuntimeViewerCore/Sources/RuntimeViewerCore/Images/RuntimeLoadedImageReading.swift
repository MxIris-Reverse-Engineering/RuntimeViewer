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
@_spi(Internals) import SwiftObjCInterop

/// What every engine read before offline mode: the images dyld loaded into
/// this process, whose metadata can be instantiated.
enum RuntimeLoadedImageReading: RuntimeImageReading {
    typealias MachO = MachOImage

    /// Instantiates the class's metadata and follows its superclass pointers,
    /// Objective-C ancestors included. A generic class has no metadata to
    /// instantiate without arguments, and answers with nothing.
    static func classHierarchy(
        of classDescriptor: ClassDescriptor,
        mangledTypeName: String,
        in machO: MachOImage,
        across aggregate: RuntimeSwiftInterfaceIndexer<Self>
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
