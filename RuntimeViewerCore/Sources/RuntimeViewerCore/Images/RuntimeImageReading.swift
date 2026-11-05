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

/// A way an engine reads an image: what dyld mapped into this process
/// (`RuntimeLoadedImageReading`, over `MachOImage`), or a file on disk
/// (`RuntimeFileImageReading`, over `MachOFile`).
///
/// The sections, their indexers, the factories and the relationship resolvers
/// are generic over this, and everything that differs between the two ways of
/// reading is a requirement here — so the generic code never asks which one it
/// holds: where a Swift class's superclass chain is read from, where an
/// Objective-C class and protocol keep their names, how the private
/// discriminator index is built, and how a generic type is specialized (by
/// instantiating metadata in this process, or statically).
///
/// A strategy type rather than a protocol the two readers adopt: `MachOFile`
/// is a class that is not final, which cannot satisfy a requirement naming
/// `Self` inside another generic type, such as `GenericSpecializer<Self>`.
protocol RuntimeImageReading: Sendable {
    associatedtype MachO: MachOFieldLayoutRenderable, ObjCMetadataSource, Sendable

    /// The names of a Swift class and of its superclasses, the class itself
    /// first — what `RuntimeEngine.hierarchy(for:)` answers for a Swift class.
    ///
    /// `aggregate` is the factory's aggregate indexer, which spans every image
    /// indexed so far: a reader that cannot run the class's metadata accessor
    /// walks the superclass names recorded there.
    static func classHierarchy(
        of classDescriptor: ClassDescriptor,
        mangledTypeName: String,
        in machO: MachO,
        across aggregate: RuntimeSwiftInterfaceIndexer<Self>
    ) throws -> [String]

    /// The name in an Objective-C class's read-only data.
    static func objcRuntimeName(of objcClass: ObjCClass64, in machO: MachO) -> String?

    /// The runtime name and flags of every Objective-C protocol record the
    /// image lists. MachOObjCSection reads a record's name through an overload
    /// per way of reading, so generic code cannot ask for it directly.
    static func objcProtocolRecords(in machO: MachO) -> [(name: String, flags: UInt32)]

    /// The index that recovers the source files of the image's private
    /// discriminators. MachOSwiftSection builds it through an initializer per
    /// way of reading.
    static func makePrivateDiscriminatorSourceFileIndex(indexer: SwiftDeclarationIndexer<MachO>) -> PrivateDiscriminatorSourceFileIndex

    /// Checks `selection` against the requirements of the type `request` names,
    /// with the evidence this way of reading has.
    static func preflight(
        _ selection: SpecializationSelection,
        for request: SpecializationRequest,
        using specializer: GenericSpecializer<MachO>
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
        using specializer: GenericSpecializer<MachO>,
        in machO: MachO
    ) async throws -> TypeDefinition
}
