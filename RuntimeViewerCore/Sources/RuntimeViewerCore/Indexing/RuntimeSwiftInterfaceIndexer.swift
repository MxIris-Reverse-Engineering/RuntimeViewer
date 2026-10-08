import SwiftDeclaration
@_spi(Support) import SwiftIndexing
import Demangling
import Foundation
import MachOKit
import MachOSwiftSection
import OrderedCollections
import SwiftStdlibToolbox
@_spi(Internals) import SwiftInspection
@_spi(Support) import SwiftInterface

/// A Swift type found to subclass another type or to conform to a protocol,
/// paired with the image that named it.
///
/// The Swift counterpart of `RuntimeObjCClassReference`. There is no
/// `isSwiftStable` here: a type reached through the Swift tables is a Swift type
/// by construction, whereas the ObjC tables carry both and have to say which.
///
/// Deliberately neither `public` nor `Codable`, for the same reason as the ObjC
/// one: relationship references never leave the process — what crosses the XPC
/// boundary is the already-materialized `RuntimeObject`.
struct RuntimeSwiftTypeReference: Hashable, Sendable {
    let mangledName: String
    let imagePath: String
}

/// A Swift protocol paired with the image declaring it, addressed both by
/// the qualified name the indexer keys protocols by and by the mangled name
/// a `RuntimeObject` carries.
struct RuntimeSwiftProtocolReference: Hashable, Sendable {
    let qualifiedName: String
    let mangledName: String
    let imagePath: String
}

/// A protocol named in another protocol's requirement signature as a base
/// conformance: a Swift protocol by qualified name, or an Objective-C
/// protocol by its runtime name (`isObjC`), which the ObjC tables resolve.
struct RuntimeSwiftRefinedProtocol: Hashable, Sendable {
    let qualifiedName: String
    let isObjC: Bool
}

/// Per-image Swift interface index: a project-owned wrapper around the
/// upstream `MachOSwiftSection` `SwiftDeclarationIndexer` that layers on the
/// relationship reverse tables backing the Inspector's Relationships tab.
///
/// This is the Swift counterpart of `RuntimeObjCInterfaceIndexer`, and since
/// Evolution 0008 the two are built the same way: a library indexer does the
/// parsing, the wrapper adds the relationship tables the library does not keep,
/// and the section actor above translates into RuntimeViewer domain types.
///
/// The wording here used to say the two were *not* alike, because the ObjC
/// parsing lived in this repo and had its reverse tables built in. Both halves
/// moved into MachOObjCSection (0007 for the parsing, its 0003 for dropping the
/// tables), so the shapes converged.
///
/// What it owns beyond the upstream indexer:
///   - `subclassesBySuperclassMangledName` — the superclass → direct-subclass
///     reverse table the upstream indexer does not provide.
///   - `typeNameByMangledName` — a mangled-string → `TypeName` index, because
///     the upstream `allTypeDefinitions` is keyed by `TypeName`, not by the
///     mangled string the relationships pipeline travels in.
/// Both are built once, eagerly, by `prepare()` — right after
/// `upstream.prepare()`, while the image is being indexed — so a later
/// Relationships-tab query is an O(1) dictionary lookup rather than an O(N)
/// demangle pass on the user interaction.
///
/// `RuntimeSwiftSection` keeps driving interface generation and generic
/// specialization directly off `upstream`; this wrapper does not gate that.
/// The encapsulation it provides is narrow and deliberate: the *relationship
/// indexing* (the reverse-table build plus the queries) lives here instead of
/// inline in the section's `init`.
///
/// Aggregation: `addSubIndexer(_:)` registers a per-image indexer, and the
/// query methods (`subclasses(of:)`, `conformingTypes(of:)`,
/// `typeName(forMangledName:)`) fan out across `self` plus every registered
/// sub-indexer — so a query against the `RuntimeSwiftSectionFactory`
/// aggregate, which holds every per-image indexer, spans all loaded images.
/// Mirrors `RuntimeObjCInterfaceIndexer`.
///
/// `@unchecked Sendable`: the `MachOImage` and `SwiftDeclaration.TypeName`
/// values held here are not themselves `Sendable`, but `machO` / `upstream`
/// are immutable `let`s and the reverse tables plus `subIndexers` are all
/// `@Mutex`-guarded — mirroring `RuntimeObjCInterfaceIndexer`.
@dynamicMemberLookup
final class RuntimeSwiftInterfaceIndexer: @unchecked Sendable {

    // MARK: - Indexed Image

    /// The Mach-O image this indexer parses. Bound at `init`, never
    /// reassigned — mirrors `RuntimeObjCInterfaceIndexer`, which likewise
    /// binds its `MachOImage` at construction.
    private let machO: MachOImage

    /// The dyld-canonical path this indexer's image is cached under — the key
    /// `RuntimeSwiftSectionFactory.sections` uses, and therefore the one every
    /// `RuntimeSwiftTypeReference` this indexer produces must carry. Not the
    /// same string as `machO.imagePath`; see `init`.
    let imagePath: String

    // MARK: - Upstream Indexer

    /// The upstream `MachOSwiftSection` indexer. Exposed (`internal`) because
    /// `RuntimeSwiftSection` drives interface generation, member-address
    /// lookup and generic specialization directly off its full API; this
    /// wrapper only *adds* the relationship layer, it does not hide `upstream`.
    let upstream: SwiftDeclarationIndexer<MachOImage>

    /// Transparent read-through to `upstream`: any property this wrapper does
    /// not declare itself resolves against `SwiftDeclarationIndexer`, so
    /// `RuntimeSwiftSection` can treat the wrapper as its indexer for
    /// interface-generation reads (`allTypeDefinitions`, `rootTypeDefinitions`,
    /// …) without spelling out `.upstream`. Methods are not key-path-
    /// expressible, so the upstream methods the codebase needs are exposed as
    /// explicit wrapper methods (see `updateConfiguration`, `addSubIndexer`).
    subscript<Value>(dynamicMember keyPath: KeyPath<SwiftDeclarationIndexer<MachOImage>, Value>) -> Value {
        upstream[keyPath: keyPath]
    }

    // MARK: - Relationship Reverse Tables

    /// Superclass mangled type-name → mangled type-names of its direct Swift
    /// subclasses in this image. The upstream indexer does not build this;
    /// `prepare()` does, with a demangle+remangle round-trip so the key sits
    /// in the same canonical string space as `mangleAsString(typeName.node)`.
    /// A subclass of a generic class bound to arguments is filed twice: under
    /// the bound name it inherits from, and under the generic class's own
    /// name, which is the one the generic class is listed and asked about by.
    /// Insertion order preserved per superclass via `OrderedSet`, so result
    /// ordering across queries is stable.
    @Mutex
    private var subclassesBySuperclassMangledName: [String: OrderedSet<String>] = [:]

    /// `mangleAsString(typeName.node)` → the originating `TypeName`. The
    /// upstream `allTypeDefinitions` is keyed by `TypeName`; this index lets
    /// a caller holding only the mangled string recover the `TypeName` in
    /// `O(1)` instead of re-scanning and re-mangling every definition.
    @Mutex
    private var typeNameByMangledName: [String: SwiftDeclaration.TypeName] = [:]

    /// Protocol counterpart of `typeNameByMangledName`:
    /// `mangleAsString(protocolName.node)` → the originating `ProtocolName`.
    /// Lets a jump target that mangles to a protocol recover its
    /// `ProtocolName` in `O(1)` for `makeRuntimeObject(forMangledProtocolName:)`.
    @Mutex
    private var protocolNameByMangledName: [String: SwiftDeclaration.ProtocolName] = [:]

    /// Mangled class name → mangled name of its superclass, for every class
    /// with one — the generic class itself when the superclass is bound to
    /// generic arguments, since that is the name the type tables know it
    /// by — plus the superclass's printed name for the case where the
    /// superclass is not a Swift type this aggregate knows (an Objective-C
    /// class, or one in an unindexed image). Recorded by `prepare()` while
    /// building the subclass table, which already resolves the superclass.
    @Mutex
    private var superclassMangledNameByMangledName: [String: String] = [:]

    @Mutex
    private var superclassDisplayNameByMangledName: [String: String] = [:]

    /// The runtime name of that superclass when it is an imported
    /// Objective-C class (`__C.NSView`), for the relationship walk to look it
    /// up by on the Objective-C side. Never derived from the printed name,
    /// which names Swift classes too — a generic one with its arguments —
    /// and whose last component can be any unrelated Objective-C class's
    /// name.
    @Mutex
    private var superclassObjCClassNameByMangledName: [String: String] = [:]

    /// Qualified protocol name → the protocols it refines, read from the
    /// requirement signature's base-conformance entries (the ones on `Self`).
    /// Built by `prepare()`; the Find navigator's Ancestor Types walks it.
    @Mutex
    private var refinedProtocolsByQualifiedName: [String: OrderedSet<RuntimeSwiftRefinedProtocol>] = [:]

    /// The reverse of `refinedProtocolsByQualifiedName`: a protocol name —
    /// Swift qualified or Objective-C — → the protocols of this image refining
    /// it. Descendent Types walks it.
    @Mutex
    private var refiningProtocolsByQualifiedName: [String: OrderedSet<RuntimeSwiftProtocolReference>] = [:]

    /// Qualified protocol name → its reference, so a name from a requirement
    /// signature can be materialized without a linear scan.
    @Mutex
    private var protocolReferenceByQualifiedName: [String: RuntimeSwiftProtocolReference] = [:]

    /// Per-image sub-indexers registered via `addSubIndexer`. Empty on a
    /// section's own indexer; on the `RuntimeSwiftSectionFactory` aggregate it
    /// holds every loaded image's indexer, so the query methods fan out across
    /// all of them. `@Mutex`-guarded because the factory keeps registering as
    /// images load. Mirrors `RuntimeObjCInterfaceIndexer.subIndexers`.
    @Mutex
    private var subIndexers: [RuntimeSwiftInterfaceIndexer] = []

    // MARK: - Init

    /// `machO` and `imagePath` are bound here and never change; `eventHandlers`
    /// is forwarded straight to the upstream indexer (`RuntimeSwiftSection`
    /// builds the progress-event handler). Mirrors
    /// `RuntimeObjCInterfaceIndexer.init`, which likewise takes both.
    ///
    /// `imagePath` is passed in rather than read off `machO` because the two are
    /// not interchangeable: the factories key their section caches by the
    /// dyld-canonical path that `DyldUtilities.patchImagePathForDyld` produces,
    /// while `machO.imagePath` is whatever dyld reported. A reference stamped
    /// with the latter fails to find its own section on the way back — which is
    /// exactly what `RuntimeRelationshipsResolver` does with these results.
    ///
    /// `configuration` is fixed for the indexer's lifetime. Callers pass
    /// `RuntimeSwiftSection.indexConfiguration`; the indexer has no say in it.
    init(
        machO: MachOImage,
        imagePath: String,
        configuration: SwiftDeclarationIndexConfiguration,
        eventHandlers: [SwiftIndexEvents.Handler] = []
    ) {
        self.machO = machO
        self.imagePath = imagePath
        self.upstream = .init(configuration: configuration, eventHandlers: eventHandlers, in: machO)
    }

    // MARK: - Preparation

    /// Run the upstream extraction, then build the relationship reverse
    /// tables over `upstream.allTypeDefinitions`. Called once by
    /// `RuntimeSwiftSection.init`, after which the tables are immutable.
    ///
    /// Eager by design: the cost is `O(N)` over `allTypeDefinitions` with a
    /// demangle+remangle per type, paid once per image-section construction
    /// regardless of whether the user ever opens the Relationships tab — so
    /// the query path stays an `O(1)` dictionary lookup.
    func prepare(progressContinuation: LoadingEventContinuation? = nil) async throws {
        try await upstream.prepare()

        progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
            phase: .indexingSwiftSubclasses,
            itemDescription: "",
            currentCount: 0,
            totalCount: upstream.allTypeDefinitions.count
        )))

        // Build into locals, then assign through the `@Mutex` once each — so
        // no lock is held across the `await mangleAsString` suspension points.
        //
        // The ObjC side has no counterpart to this: its tables are folded by
        // the event handler during `upstream.prepare()`, one synchronous event
        // at a time, so there is no suspension point for a lock to span. That
        // asymmetry follows from where each library puts its relationship data
        // — an event stream on one side, a queryable store on the other — and
        // is the reason `RuntimeObjCInterfaceIndexer.prepare()` is a bare
        // forward while this one does work.
        var subclassTable: [String: OrderedSet<String>] = [:]
        var typeNameTable: [String: SwiftDeclaration.TypeName] = [:]
        var protocolNameTable: [String: SwiftDeclaration.ProtocolName] = [:]
        var superclassMangledNameTable: [String: String] = [:]
        var superclassDisplayNameTable: [String: String] = [:]
        var superclassObjCClassNameTable: [String: String] = [:]
        var refinedProtocolsTable: [String: OrderedSet<RuntimeSwiftRefinedProtocol>] = [:]
        var refiningProtocolsTable: [String: OrderedSet<RuntimeSwiftProtocolReference>] = [:]
        var protocolReferenceTable: [String: RuntimeSwiftProtocolReference] = [:]
        for (protocolName, protocolDefinition) in upstream.allProtocolDefinitions {
            guard let key = try? await mangleAsString(protocolName.node) else { continue }
            protocolNameTable[key] = protocolName
            let qualifiedName = protocolName.name
            let reference = RuntimeSwiftProtocolReference(qualifiedName: qualifiedName, mangledName: key, imagePath: imagePath)
            protocolReferenceTable[qualifiedName] = reference
            for refined in await refinedProtocols(ofProtocolDescribedBy: protocolDefinition.protocolDescriptor) {
                refinedProtocolsTable[qualifiedName, default: []].append(refined)
                refiningProtocolsTable[refined.qualifiedName, default: []].append(reference)
            }
        }
        for (typeName, typeDefinition) in upstream.allTypeDefinitions {
            // Record `mangledName -> TypeName` for every type, regardless of
            // whether it is a class. `RuntimeSwiftSection.makeRuntimeObject`
            // walks this map to recover the kind/displayName for both
            // subclass results (always classes) and protocol conformer
            // results (any nominal kind).
            //
            // `mangleAsString` has sync + async overloads; in this `async`
            // function the compiler picks the async one, hence `await`.
            // `try?` flattens the nested Optional per SE-0230, so the binding
            // is `String`, not `String?`.
            guard let childKey = try? await mangleAsString(typeName.node) else { continue }
            typeNameTable[childKey] = typeName

            guard case .class(let classDescriptor) = typeDefinition.typeContextDescriptorWrapper else { continue }
            guard let superclassMangled = try? classDescriptor.superclassTypeMangledName(in: machO.context)
            else { continue }
            // Round-trip through demangle + remangle so the superclass key
            // sits in the same canonical string space as the child key
            // (`mangleAsString(typeName.node)`), which is also how the
            // relationships pipeline derives the lookup key from a target
            // Swift class.
            guard let superclassNode = try? SymbolicDemangler.demangleType(for: superclassMangled, in: machO.context),
                  let superclassKey = try? await mangleAsString(superclassNode)
            else { continue }
            // A superclass bound to generic arguments
            // (`IncrementalUpdateAction<Menu, MenuItem>`) is filed under the
            // generic class as well: that is the name the type tables know it
            // by, and the one Descendent Types and the Inspector ask about it
            // under. The bound name stays for a type the user specialized,
            // whose name is the bound one.
            let unspecializedSuperclassNode = Self.unspecializedNominalTypeNode(of: superclassNode)
            var unspecializedSuperclassKey: String?
            if let unspecializedSuperclassNode {
                unspecializedSuperclassKey = try? await mangleAsString(unspecializedSuperclassNode)
            }
            subclassTable[superclassKey, default: []].append(childKey)
            if let unspecializedSuperclassKey, unspecializedSuperclassKey != superclassKey {
                subclassTable[unspecializedSuperclassKey, default: []].append(childKey)
            }
            superclassMangledNameTable[childKey] = unspecializedSuperclassKey ?? superclassKey
            superclassDisplayNameTable[childKey] = await superclassNode.print(using: .interfaceTypeBuilderOnly)
            if let objcClassName = Self.importedObjCClassName(of: unspecializedSuperclassNode ?? superclassNode) {
                superclassObjCClassNameTable[childKey] = objcClassName
            }
        }
        subclassesBySuperclassMangledName = subclassTable
        typeNameByMangledName = typeNameTable
        protocolNameByMangledName = protocolNameTable
        superclassMangledNameByMangledName = superclassMangledNameTable
        superclassDisplayNameByMangledName = superclassDisplayNameTable
        superclassObjCClassNameByMangledName = superclassObjCClassNameTable
        refinedProtocolsByQualifiedName = refinedProtocolsTable
        refiningProtocolsByQualifiedName = refiningProtocolsTable
        protocolReferenceByQualifiedName = protocolReferenceTable
    }

    /// The protocols a protocol refines: the requirement-signature entries
    /// whose subject is `Self` (mangled `x`) and whose content is a protocol.
    /// A Swift protocol is named the way `ProtocolName.name` names it, so the
    /// result keys straight into the aggregate's protocol tables; an
    /// Objective-C protocol is named by its runtime name and flagged. Entries
    /// that cannot be resolved are dropped rather than guessed at.
    private func refinedProtocols(ofProtocolDescribedBy descriptor: ProtocolDescriptor) async -> [RuntimeSwiftRefinedProtocol] {
        guard let protocolModel = try? MachOSwiftSection.`Protocol`(descriptor: descriptor, in: machO.context) else { return [] }
        var result: [RuntimeSwiftRefinedProtocol] = []
        for requirement in protocolModel.requirementInSignatures {
            guard requirement.paramManagledName.rawString == "x",
                  case .protocol(let symbolOrElement) = requirement.content
            else { continue }
            switch symbolOrElement {
            case .symbol(let symbol):
                guard let node = try? SymbolicDemangler.demangleType(for: symbol, in: machO.context) else { continue }
                let qualifiedName = await node.print(using: .interfaceTypeBuilderOnly)
                guard !qualifiedName.isEmpty else { continue }
                result.append(RuntimeSwiftRefinedProtocol(qualifiedName: qualifiedName, isObjC: false))
            case .element(let descriptorWithObjCInterop):
                switch descriptorWithObjCInterop {
                case .swift(let refinedDescriptor):
                    guard let node = try? SymbolicDemangler.demangleContext(for: .protocol(refinedDescriptor), in: machO.context) else { continue }
                    let qualifiedName = await node.print(using: .interfaceTypeBuilderOnly)
                    guard !qualifiedName.isEmpty else { continue }
                    result.append(RuntimeSwiftRefinedProtocol(qualifiedName: qualifiedName, isObjC: false))
                case .objc(let objcProtocol):
                    guard let name = try? objcProtocol.name(in: machO.context), !name.isEmpty else { continue }
                    result.append(RuntimeSwiftRefinedProtocol(qualifiedName: name, isObjC: true))
                }
            }
        }
        return result
    }

    // MARK: - Superclass Names

    /// The nominal type a type node instantiates, with every generic argument
    /// removed and spelled the way that type's own descriptor demangles:
    /// `IncrementalUpdateAction<Menu, MenuItem>` becomes
    /// `IncrementalUpdateAction`, and a bound enclosing type is unbound as
    /// well (`Outer<Int>.Inner`). `nil` when nothing in it is bound, which is
    /// the case for every non-generic superclass, so those cost no second
    /// mangling.
    ///
    /// swift-demangling's `getUnspecialized` does this for every kind of node
    /// but is internal to that library. A superclass is always a nominal type,
    /// so this covers what can occur here, under the same rules: a bound
    /// generic node gives way to the type it binds, and a nominal type or an
    /// extension is rebuilt around its unspecialized context.
    private static func unspecializedNominalTypeNode(of typeNode: Node) -> Node? {
        guard let nominalNode = unspecializedNominalNode(of: typeNode) else { return nil }
        return Node.create(kind: .type, child: nominalNode)
    }

    /// `unspecializedNominalTypeNode(of:)` below the `type` wrapper.
    private static func unspecializedNominalNode(of node: Node) -> Node? {
        switch node.kind {
        case .type:
            return node.firstChild.flatMap(unspecializedNominalNode(of:))
        case .boundGenericClass,
             .boundGenericStructure,
             .boundGenericEnum,
             .boundGenericOtherNominalType,
             .boundGenericTypeAlias:
            guard let unboundTypeNode = node.firstChild,
                  unboundTypeNode.kind == .type,
                  let nominalNode = unboundTypeNode.firstChild
            else { return nil }
            return unspecializedNominalNode(of: nominalNode) ?? nominalNode
        case .class,
             .structure,
             .enum,
             .otherNominalType,
             .typeAlias:
            guard let contextNode = node.firstChild,
                  let unspecializedContextNode = unspecializedNominalNode(of: contextNode)
            else { return nil }
            return Node.create(kind: node.kind, children: [unspecializedContextNode] + node.children.dropFirst())
        case .extension:
            // The module, the extended type, and the extension's generic
            // signature when it has one.
            guard node.children.count >= 2,
                  let unspecializedExtendedTypeNode = unspecializedNominalNode(of: node.children[1])
            else { return nil }
            return Node.create(kind: .extension, children: [node.children[0], unspecializedExtendedTypeNode] + node.children.dropFirst(2))
        default:
            return nil
        }
    }

    /// The runtime name of the Objective-C class a type node names — a class
    /// of the Clang importer's `__C` module, such as the `NSView` a Swift
    /// view subclasses — or `nil` for any other type. An imported class is
    /// mangled under its Objective-C name, so this is the name the
    /// Objective-C tables know it by.
    private static func importedObjCClassName(of typeNode: Node) -> String? {
        var node = typeNode
        while node.kind == .type, let childNode = node.firstChild {
            node = childNode
        }
        guard node.kind == .class,
              let moduleNode = node.firstChild,
              moduleNode.kind == .module,
              moduleNode.text == "__C",
              let identifierNode = node[safeChild: 1],
              identifierNode.kind == .identifier
        else { return nil }
        return identifierNode.text
    }

    // MARK: - Relationship Query

    /// Direct Swift subclasses of the type whose mangled name is
    /// `superclassMangledName` — this indexer's own image plus every
    /// sub-indexer registered via `addSubIndexer`. On a per-image indexer (no
    /// sub-indexers) the result is just this image; on the factory aggregate it
    /// spans every loaded image. Per-superclass insertion order is preserved via
    /// `OrderedSet`; cross-image order follows `subIndexers` registration order.
    ///
    /// Each result carries the image that named the type, because a cross-image
    /// query's caller cannot otherwise tell where a mangled name came from, and
    /// `RuntimeSwiftSection.makeRuntimeObject(forMangledTypeName:)` stamps the
    /// section's *own* `imagePath` onto what it builds. Mirrors
    /// `RuntimeObjCInterfaceIndexer.subclasses(of:)`, whose references have
    /// carried their image all along.
    func subclasses(of superclassMangledName: String) -> [RuntimeSwiftTypeReference] {
        var result: OrderedSet<RuntimeSwiftTypeReference> = []
        for mangledName in subclassesBySuperclassMangledName[superclassMangledName] ?? [] {
            result.append(RuntimeSwiftTypeReference(mangledName: mangledName, imagePath: imagePath))
        }
        for subIndexer in subIndexers {
            for reference in subIndexer.subclasses(of: superclassMangledName) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    /// All Swift conforming types of the given protocol — this indexer's own
    /// image (via the upstream indexer's `conformingTypesByProtocolName`,
    /// populated during `upstream.prepare()`) plus every registered
    /// sub-indexer. Per-image on a section's indexer; cross-image on the factory
    /// aggregate. Results carry their originating image for the same reason as
    /// `subclasses(of:)`.
    func conformingTypes(of protocolName: String) -> [RuntimeSwiftTypeReference] {
        var result: OrderedSet<RuntimeSwiftTypeReference> = []
        if let conformers = upstream.conformingTypesByProtocolName.first(where: { $0.key.name == protocolName })?.value {
            for conformer in conformers {
                if let mangledName = try? mangleAsString(conformer.node) {
                    result.append(RuntimeSwiftTypeReference(mangledName: mangledName, imagePath: imagePath))
                }
            }
        }
        for subIndexer in subIndexers {
            for reference in subIndexer.conformingTypes(of: protocolName) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    /// The `TypeName` a mangled type-name string maps to, or `nil` when no
    /// indexer in this aggregate names that type. Checks this indexer's own
    /// image first, then each registered sub-indexer — so on the factory
    /// aggregate the lookup spans every loaded image. `RuntimeSwiftSection`
    /// uses it to translate a relationship result back into a `RuntimeObject`.
    func typeName(forMangledName mangledName: String) -> SwiftDeclaration.TypeName? {
        if let typeName = typeNameByMangledName[mangledName] {
            return typeName
        }
        for subIndexer in subIndexers {
            if let typeName = subIndexer.typeName(forMangledName: mangledName) {
                return typeName
            }
        }
        return nil
    }

    /// The `ProtocolName` a mangled protocol-name string maps to, or `nil`
    /// when no indexer in this aggregate names that protocol. Fans out across
    /// this indexer's own image and every registered sub-indexer, mirroring
    /// `typeName(forMangledName:)`.
    func protocolName(forMangledName mangledName: String) -> SwiftDeclaration.ProtocolName? {
        if let protocolName = protocolNameByMangledName[mangledName] {
            return protocolName
        }
        for subIndexer in subIndexers {
            if let protocolName = subIndexer.protocolName(forMangledName: mangledName) {
                return protocolName
            }
        }
        return nil
    }
    
    /// The type definition behind a mangled type name and the image that
    /// declares it, from whichever indexer in this aggregate names the type.
    func typeDefinition(forMangledName mangledName: String) -> (definition: TypeDefinition, imagePath: String)? {
        if let typeName = typeNameByMangledName[mangledName], let definition = upstream.allTypeDefinitions[typeName] {
            return (definition, imagePath)
        }
        for subIndexer in subIndexers {
            if let found = subIndexer.typeDefinition(forMangledName: mangledName) {
                return found
            }
        }
        return nil
    }

    /// The protocols the type with this mangled name conforms to, as its
    /// declaring image indexed them (direct conformances, in record order).
    func conformingProtocolNames(forMangledTypeName mangledName: String) -> [SwiftDeclaration.ProtocolName] {
        if let typeName = typeNameByMangledName[mangledName] {
            return Array(upstream.conformingProtocolNamesByTypeName[typeName] ?? [])
        }
        for subIndexer in subIndexers {
            if subIndexer.typeNameByMangledName[mangledName] != nil {
                return subIndexer.conformingProtocolNames(forMangledTypeName: mangledName)
            }
        }
        return []
    }

    /// The mangled name of the superclass of the class with this mangled
    /// name — the generic class itself when the superclass is bound to
    /// arguments — or `nil` for a root class or a type this aggregate does
    /// not know. The superclass itself need not be known to any indexer.
    func superclassMangledName(forMangledTypeName mangledName: String) -> String? {
        if let superclass = superclassMangledNameByMangledName[mangledName] {
            return superclass
        }
        for subIndexer in subIndexers {
            if let superclass = subIndexer.superclassMangledName(forMangledTypeName: mangledName) {
                return superclass
            }
        }
        return nil
    }

    /// The printed name of that superclass, for a superclass no indexer can
    /// materialize — an Objective-C class, or one in an unindexed image.
    func superclassDisplayName(forMangledTypeName mangledName: String) -> String? {
        if let name = superclassDisplayNameByMangledName[mangledName] {
            return name
        }
        for subIndexer in subIndexers {
            if let name = subIndexer.superclassDisplayName(forMangledTypeName: mangledName) {
                return name
            }
        }
        return nil
    }

    /// The runtime name of that superclass when it is an imported
    /// Objective-C class, the name the Objective-C tables know it by. `nil`
    /// for a Swift superclass, which only the Swift tables can resolve.
    func superclassObjCClassName(forMangledTypeName mangledName: String) -> String? {
        if let name = superclassObjCClassNameByMangledName[mangledName] {
            return name
        }
        for subIndexer in subIndexers {
            if let name = subIndexer.superclassObjCClassName(forMangledTypeName: mangledName) {
                return name
            }
        }
        return nil
    }

    /// The protocols `qualifiedName` refines, from the image declaring it.
    func refinedProtocols(ofQualifiedName qualifiedName: String) -> [RuntimeSwiftRefinedProtocol] {
        if let refined = refinedProtocolsByQualifiedName[qualifiedName] {
            return Array(refined)
        }
        for subIndexer in subIndexers {
            if subIndexer.protocolReferenceByQualifiedName[qualifiedName] != nil {
                return subIndexer.refinedProtocols(ofQualifiedName: qualifiedName)
            }
        }
        return []
    }

    /// The protocols refining `name` — a Swift qualified name or an
    /// Objective-C protocol name — across this indexer and every sub-indexer.
    func refiningProtocols(ofQualifiedName name: String) -> [RuntimeSwiftProtocolReference] {
        var result = refiningProtocolsByQualifiedName[name] ?? []
        for subIndexer in subIndexers {
            for reference in subIndexer.refiningProtocols(ofQualifiedName: name) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    /// The reference of the protocol with this qualified name, from whichever
    /// indexer declares it.
    func protocolReference(forQualifiedName qualifiedName: String) -> RuntimeSwiftProtocolReference? {
        if let reference = protocolReferenceByQualifiedName[qualifiedName] {
            return reference
        }
        for subIndexer in subIndexers {
            if let reference = subIndexer.protocolReference(forQualifiedName: qualifiedName) {
                return reference
            }
        }
        return nil
    }

    // MARK: - Aggregation

    /// Register a per-image indexer with this aggregate. Appends it to
    /// `subIndexers` so the query methods fan out into it, and forwards the
    /// sub-indexer's `upstream` to `upstream.addSubIndexer` so the upstream's
    /// own cross-image lookups (`allAllTypeDefinitions`, …) see it too.
    /// Callers pass `RuntimeSwiftInterfaceIndexer` values and never reach for
    /// `.upstream`. Mirrors `RuntimeObjCInterfaceIndexer.addSubIndexer(_:)`;
    /// `RuntimeSwiftSectionFactory` calls it as each section is created.
    ///
    /// Both registrations happen under `subIndexers`' lock, because
    /// `removeSubIndexer` has to address the upstream one *by index* and can
    /// only do that if the two arrays stay in lockstep. Registering outside the
    /// lock leaves a window in which two concurrent calls interleave the two
    /// appends differently and the arrays permanently disagree.
    func addSubIndexer(_ subIndexer: RuntimeSwiftInterfaceIndexer) {
        _subIndexers.withLock { subIndexers in
            upstream.addSubIndexer(subIndexer.upstream)
            subIndexers.append(subIndexer)
        }
    }

    /// Detach a previously registered per-image indexer, undoing both the local
    /// registration and the upstream one.
    ///
    /// **`addSubIndexer` without this is a leak, not an inconvenience.** This
    /// aggregate lives as long as its factory — i.e. as long as the owning
    /// `RuntimeEngine` — so a registration that is never undone pins that
    /// image's whole declaration graph (including the definitions' `NodeStore`)
    /// for the engine's lifetime, and `removeSection(for:)` reclaims nothing
    /// however carefully it drops its own entry.
    ///
    /// The upstream API removes *by index*, so this takes the lock for the whole
    /// operation and uses one index for both arrays — see `addSubIndexer`.
    /// Identity comparison, not equality: two indexers over the same image are
    /// still two indexers.
    func removeSubIndexer(_ subIndexer: RuntimeSwiftInterfaceIndexer) {
        _subIndexers.withLock { subIndexers in
            guard let index = subIndexers.firstIndex(where: { $0 === subIndexer }) else { return }
            subIndexers.remove(at: index)
            upstream.removeSubIndexer(at: index)
        }
    }
}
