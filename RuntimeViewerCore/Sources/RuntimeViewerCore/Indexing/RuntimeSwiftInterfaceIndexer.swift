import Demangling
import Foundation
import MachOKit
import MachOSwiftSection
import OrderedCollections
import SwiftStdlibToolbox
@_spi(Internals) import SwiftInspection
@_spi(Support) import SwiftInterface

/// Per-image Swift interface index: a project-owned wrapper around the
/// upstream `MachOSwiftSection` `SwiftInterfaceIndexer` that layers on the
/// relationship reverse tables backing the Inspector's Relationships tab.
///
/// This is the Swift counterpart of `RuntimeObjCInterfaceIndexer`, but the
/// two are not built the same way. On the ObjC side `RuntimeObjCInterfaceIndexer`
/// *is* the indexer — it parses `MachOObjCSection` / `ObjCDump` itself. On the
/// Swift side the heavy parsing is already done by the upstream
/// `SwiftInterfaceIndexer`, which we neither own nor can extend; so this type
/// *wraps* one (`upstream`) and adds only the RuntimeViewer-specific
/// relationship indexing on top.
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
/// `@unchecked Sendable`: the `MachOImage` and `SwiftInterface.TypeName`
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

    // MARK: - Upstream Indexer

    /// The upstream `MachOSwiftSection` indexer. Exposed (`internal`) because
    /// `RuntimeSwiftSection` drives interface generation, member-address
    /// lookup and generic specialization directly off its full API; this
    /// wrapper only *adds* the relationship layer, it does not hide `upstream`.
    let upstream: SwiftInterfaceIndexer<MachOImage>

    /// Transparent read-through to `upstream`: any property this wrapper does
    /// not declare itself resolves against `SwiftInterfaceIndexer`, so
    /// `RuntimeSwiftSection` can treat the wrapper as its indexer for
    /// interface-generation reads (`allTypeDefinitions`, `rootTypeDefinitions`,
    /// …) without spelling out `.upstream`. Methods are not key-path-
    /// expressible, so the upstream methods the codebase needs are exposed as
    /// explicit wrapper methods (see `updateConfiguration`, `addSubIndexer`).
    subscript<Value>(dynamicMember keyPath: KeyPath<SwiftInterfaceIndexer<MachOImage>, Value>) -> Value {
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
    private var typeNameByMangledName: [String: SwiftInterface.TypeName] = [:]

    /// Per-image sub-indexers registered via `addSubIndexer`. Empty on a
    /// section's own indexer; on the `RuntimeSwiftSectionFactory` aggregate it
    /// holds every loaded image's indexer, so the query methods fan out across
    /// all of them. `@Mutex`-guarded because the factory keeps registering as
    /// images load. Mirrors `RuntimeObjCInterfaceIndexer.subIndexers`.
    @Mutex
    private var subIndexers: [RuntimeSwiftInterfaceIndexer] = []

    // MARK: - Init

    /// `machO` is bound here and never changes; `eventHandlers` is forwarded
    /// straight to the upstream indexer (`RuntimeSwiftSection` builds the
    /// progress-event handler). Mirrors `RuntimeObjCInterfaceIndexer.init`,
    /// where the image is likewise bound at construction.
    init(machO: MachOImage, eventHandlers: [SwiftInterfaceEvents.Handler] = []) {
        self.machO = machO
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
        // Mirrors `RuntimeObjCInterfaceIndexer.prepare()`.
        var subclassTable: [String: OrderedSet<String>] = [:]
        var typeNameTable: [String: SwiftInterface.TypeName] = [:]
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

            guard case .class(let classWrapper) = typeDefinition.type else { continue }
            let classDescriptor = classWrapper.descriptor
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
    }

    // MARK: - Relationship Query

    /// Direct Swift subclasses of the type whose mangled name is
    /// `superclassMangledName`, as mangled type-name strings — this indexer's
    /// own image plus every sub-indexer registered via `addSubIndexer`. On a
    /// per-image indexer (no sub-indexers) the result is just this image; on
    /// the factory aggregate it spans every loaded image. Per-superclass
    /// insertion order is preserved via `OrderedSet`; cross-image order
    /// follows `subIndexers` registration order.
    func subclasses(of superclassMangledName: String) -> [String] {
        var result: OrderedSet<String> = subclassesBySuperclassMangledName[superclassMangledName] ?? []
        for subIndexer in subIndexers {
            for mangled in subIndexer.subclasses(of: superclassMangledName) {
                result.append(mangled)
            }
        }
        return Array(result)
    }

    /// All Swift conforming types of the given protocol, as mangled type-name
    /// strings — this indexer's own image (via the upstream indexer's
    /// `conformingTypesByProtocolName`, populated during `upstream.prepare()`)
    /// plus every registered sub-indexer. Per-image on a section's indexer;
    /// cross-image on the factory aggregate.
    func conformingTypes(of protocolName: String) -> [String] {
        var result: OrderedSet<String> = []
        if let conformers = upstream.conformingTypesByProtocolName.first(where: { $0.key.name == protocolName })?.value {
            for conformer in conformers {
                if let mangled = try? mangleAsString(conformer.node) {
                    result.append(mangled)
                }
            }
        }
        for subIndexer in subIndexers {
            for mangled in subIndexer.conformingTypes(of: protocolName) {
                result.append(mangled)
            }
        }
        return Array(result)
    }

    /// The `TypeName` a mangled type-name string maps to, or `nil` when no
    /// indexer in this aggregate names that type. Checks this indexer's own
    /// image first, then each registered sub-indexer — so on the factory
    /// aggregate the lookup spans every loaded image. `RuntimeSwiftSection`
    /// uses it to translate a relationship result back into a `RuntimeObject`.
    func typeName(forMangledName mangledName: String) -> SwiftInterface.TypeName? {
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
    
    // MARK: - Upstream Method Forwarding

    /// Forward a configuration update to `upstream`. `@dynamicMemberLookup`
    /// forwards property *reads* only, so the upstream methods the codebase
    /// needs are wrapped explicitly — `RuntimeSwiftSection.updateConfiguration`
    /// calls this when Swift generation options change.
    func updateConfiguration(_ newConfiguration: SwiftInterfaceIndexConfiguration) async throws {
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
    func addSubIndexer(_ subIndexer: RuntimeSwiftInterfaceIndexer) {
        upstream.addSubIndexer(subIndexer.upstream)
        _subIndexers.withLock { $0.append(subIndexer) }
    }
}
