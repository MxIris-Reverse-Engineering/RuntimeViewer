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
    private let imagePath: String

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
    init(machO: MachOImage, imagePath: String, eventHandlers: [SwiftIndexEvents.Handler] = []) {
        self.machO = machO
        self.imagePath = imagePath
        self.upstream = .init(configuration: .init(showCImportedTypes: false), eventHandlers: eventHandlers, in: machO)
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
        for (protocolName, _) in upstream.allProtocolDefinitions {
            guard let key = try? await mangleAsString(protocolName.node) else { continue }
            protocolNameTable[key] = protocolName
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
            guard let superclassMangled = try? classDescriptor.superclassTypeMangledName(in: machO)
            else { continue }
            // Round-trip through demangle + remangle so the superclass key
            // sits in the same canonical string space as the child key
            // (`mangleAsString(typeName.node)`), which is also how the
            // relationships pipeline derives the lookup key from a target
            // Swift class.
            guard let superclassNode = try? MetadataReader.demangleType(for: superclassMangled, in: machO),
                  let superclassKey = try? await mangleAsString(superclassNode)
            else { continue }
            subclassTable[superclassKey, default: []].append(childKey)
        }
        subclassesBySuperclassMangledName = subclassTable
        typeNameByMangledName = typeNameTable
        protocolNameByMangledName = protocolNameTable
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
    
    // MARK: - Upstream Method Forwarding

    /// Forward a configuration update to `upstream`. `@dynamicMemberLookup`
    /// forwards property *reads* only, so the upstream methods the codebase
    /// needs are wrapped explicitly — `RuntimeSwiftSection.updateConfiguration`
    /// calls this when Swift generation options change.
    func updateConfiguration(_ newConfiguration: SwiftDeclarationIndexConfiguration) async throws {
        try await upstream.updateConfiguration(newConfiguration)
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
