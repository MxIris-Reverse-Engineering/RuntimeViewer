import Foundation
import MachOKit
import MachOObjCSection
import MachOSwiftSection
import Demangling
@_spi(Support) import SwiftDeclaration
@_spi(Support) import SwiftIndexing
@_spi(Support) import SwiftSpecialization
@_spi(Support) import SwiftPrivateDiscriminators
@_spi(Internals) import SwiftInspection

/// Offline mode: images read from a file on disk. Nothing in an image runs,
/// so every answer comes from what the file holds.
enum RuntimeFileImageReading: RuntimeImageReading {
    typealias MachO = MachOFile

    /// Walks the superclass names the aggregate indexer recorded while it
    /// indexed each image. The walk stops at the first superclass it cannot
    /// follow: an Objective-C class — named by its runtime name, without the
    /// Objective-C ancestors above it — or a Swift class in an image not
    /// indexed yet, named as the subclass prints it.
    static func classHierarchy(
        of classDescriptor: ClassDescriptor,
        mangledTypeName: String,
        in machO: MachOFile,
        across aggregate: RuntimeSwiftInterfaceIndexer<Self>
    ) throws -> [String] {
        var names = [try classDescriptor.name(in: machO.context)]
        var currentMangledName = mangledTypeName
        var visitedMangledNames: Set<String> = [mangledTypeName]
        while let superclassMangledName = aggregate.superclassMangledName(forMangledTypeName: currentMangledName) {
            if let objcClassName = aggregate.superclassObjCClassName(forMangledTypeName: currentMangledName) {
                names.append(objcClassName)
                break
            }
            guard let superclassTypeName = aggregate.typeName(forMangledName: superclassMangledName) else {
                if let displayName = aggregate.superclassDisplayName(forMangledTypeName: currentMangledName) {
                    names.append(displayName)
                }
                break
            }
            guard visitedMangledNames.insert(superclassMangledName).inserted else { break }
            names.append(superclassTypeName.name)
            currentMangledName = superclassMangledName
        }
        return names
    }

    /// A file holds only the read-only data the compiler wrote; the runtime
    /// never realized the class.
    static func objcRuntimeName(of objcClass: ObjCClass64, in machO: MachOFile) -> String? {
        objcClass.classROData(in: machO)?.name(in: machO)
    }

    static func objcProtocolRecords(in machO: MachOFile) -> [(name: String, flags: UInt32)] {
        var records: [(name: String, flags: UInt32)] = []
        for objcProtocol in machO.objc.protocols64 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        for objcProtocol in machO.objc.protocols32 ?? [] {
            records.append((name: objcProtocol.mangledName(in: machO), flags: objcProtocol.flags))
        }
        return records
    }

    static func makePrivateDiscriminatorSourceFileIndex(indexer: SwiftDeclarationIndexer<MachOFile>) -> PrivateDiscriminatorSourceFileIndex {
        PrivateDiscriminatorSourceFileIndex(indexer: indexer)
    }

    /// The evidence a file carries is incomplete, so a requirement it cannot
    /// settle — a conformance no indexed image records — is a warning rather
    /// than an error (MachOSwiftSection proposal 0069).
    static func preflight(
        _ selection: SpecializationSelection,
        for request: SpecializationRequest,
        using specializer: GenericSpecializer<MachOFile>
    ) -> SpecializationValidation {
        specializer.staticPreflight(selection: selection, for: request)
    }

    /// Specializes without metadata: the result carries the instantiation's
    /// name and every parameter's argument, which the printer and the static
    /// layout engine turn into the bound declaration. The argument nodes are
    /// in the result, so `typeArgumentNodes` and its map are not needed.
    static func specialize(
        _ typeDefinition: TypeDefinition,
        request: SpecializationRequest,
        selection: SpecializationSelection,
        typeArgumentNodes: [Node]?,
        typeArgumentNodesByParameter: [String: Node],
        using specializer: GenericSpecializer<MachOFile>,
        in machO: MachOFile
    ) async throws -> TypeDefinition {
        let result = try specializer.specialize(request, with: selection)
        return try await typeDefinition.specialize(
            with: result,
            derivingNestedSpecializationsWith: specializer,
            in: machO
        )
    }
}
