import Foundation
import FoundationToolbox
import MachOKit
import ObjCIndexing
import OrderedCollections

/// An Objective-C class — or a Swift class carrying an Objective-C ancestor —
/// found to subclass another class or to adopt a protocol.
///
/// `isSwiftStable` is the structural signal (`class_t`'s `FAST_IS_SWIFT_STABLE`
/// bit) that lets `RuntimeRelationshipsResolver` decide whether to materialize
/// the reference as a Swift `RuntimeObject` or an Objective-C one. The library
/// reports the bit; the domain judgement is made here.
///
/// Deliberately neither `public` nor `Codable`: relationship references never
/// leave the process. What crosses the XPC boundary is the already-materialized
/// `RuntimeObject`.
struct RuntimeObjCClassReference: Hashable, Sendable {
    let className: String
    let imagePath: String
    let isSwiftStable: Bool
}

/// Per-image Objective-C interface index: a project-owned wrapper around the
/// upstream `MachOObjCSection` `ObjCInterfaceIndexer` that layers on the
/// relationship reverse tables backing the Inspector's Relationships tab.
///
/// This is the Objective-C counterpart of `RuntimeSwiftInterfaceIndexer`, and
/// the two are deliberately built the same way: the library parses, this
/// wrapper remembers how the parsed things relate, and the section actor above
/// translates into RuntimeViewer domain types. See Evolution 0008.
///
/// ## Why the upstream indexer is constructed in here
///
/// Since MachOObjCSection 0003 the library keeps no reverse tables — the three
/// relationship cases of `ObjCIndexingEvent` are the *only* channel carrying
/// inheritance and protocol adoption, and an `ObjCInterfaceIndexer` built
/// without an `eventHandler` keeps none of it.
///
/// That makes "was a handler installed?" a correctness property rather than a
/// configuration detail, and it is not one a caller should be able to get
/// wrong. Evolution 0007 kept the upstream indexer at the call site and made
/// the handler unconditional there, guarded by a comment; a later edit
/// reintroducing a condition would compile, pass most tests, and silently empty
/// the Relationships pane for every image loaded without a progress stream —
/// six of the seven section-creation call sites, background indexing among
/// them.
///
/// Here `upstream` is a `let` built inside `init`, so no caller ever holds an
/// indexer whose handler was not installed. Only the *forwarding* of `.progress`
/// events is conditional, because only that half has an optional destination.
/// `RuntimeSwiftInterfaceIndexer` constructs its own upstream for the same
/// reason.
///
/// ## Tables are folded as events arrive
///
/// `RuntimeObjCRelationshipTables.fold(_:)` applies each event immediately instead of
/// queueing it for a later replay. Deferring would move a few dictionary
/// operations off the parse path, but it keeps the raw event array resident
/// until something queries the image — and most images are never queried, while
/// background indexing indexes them all. Folding also makes `prepare()`'s
/// return the point at which the tables are complete, with no second step to
/// forget.
///
/// ## Equivalence with the library's former tables
///
/// Three properties of the pre-0003 implementation are reproduced deliberately:
///
/// 1. Inline adoptions and category-contributed adoptions land in **one**
///    conformer table, so a single query returns both.
/// 2. Events fold in arrival order, so inline adoptions precede category ones
///    exactly as they did when the library walked classes before categories.
/// 3. `OrderedSet` deduplicates on all three fields, not on `className`. A class
///    can legitimately appear twice for one protocol with differing
///    `isSwiftStable` — inline adoption reads the class' own flag while a
///    category resolves its target across images and falls back to `false`.
///    Collapsing those would look like a bug fix and would be a behaviour change.
///
/// ## Aggregation
///
/// `addSubIndexer(_:)` registers a per-image indexer and `removeSubIndexer(_:)`
/// detaches it; the query methods fan out across `self` plus every registered
/// sub-indexer. A query against the `RuntimeObjCSectionFactory` aggregate — which
/// holds every per-image indexer — therefore spans all loaded images in one
/// call, which is what lets `RuntimeRelationshipsResolver` stop walking images
/// itself. Mirrors `RuntimeSwiftInterfaceIndexer`.
///
/// ## Where this and the Swift side deliberately differ
///
/// Evolution 0008 asks these two types to correspond member for member, with
/// every departure written down. The current list, and why each one is not
/// something to iron out:
///
/// - **`prepare()` takes no progress continuation; the Swift one does.** ObjC
///   progress arrives through the same `eventHandler` as the relationship
///   events, so it is supplied once at `init`. The Swift upstream reports
///   progress through `eventHandlers` *and* the wrapper emits an extra
///   `indexingSwiftSubclasses` phase around its own table build, which happens
///   in `prepare()`. Unifying that means changing when Swift reports progress,
///   which is a user-visible change and not this proposal's business.
/// - **`conformingClasses(toProtocol:)` vs `conformingTypes(of:)`.** Only
///   classes adopt Objective-C protocols; any nominal type can conform to a
///   Swift one. The names say which, and flattening them would make one of the
///   two lie.
/// - **The tables live in a separate object here.** The event handler must
///   capture its destination before `self` exists; the Swift side builds its
///   tables after `upstream.prepare()` returns and can store them inline.
/// - **No `machO` stored here.** The Swift wrapper re-reads its image during
///   `prepare()` to resolve superclass mangled names; this one hands `machO` to
///   `upstream` at `init` and never needs it again.
/// - **No `imagePath` stored here.** Each relationship event carries the path
///   the library was constructed with, so references are already stamped by the
///   time they arrive. The Swift wrapper has to keep it to stamp its own — and
///   must be given the dyld-canonical one, not `machO.imagePath`; see its `init`.
///
/// Extra members on the Swift side (`typeName(forMangledName:)`,
/// `protocolName(forMangledName:)`, `updateConfiguration`) are forwarding or
/// lookup helpers with no Objective-C counterpart to mirror, not asymmetries in
/// the relationship layer itself.
///
/// `@unchecked Sendable`: `upstream` and `relationshipTables` are immutable
/// `let`s that guard their own state, and `subIndexers` is `@Mutex`-guarded.
@dynamicMemberLookup
final class RuntimeObjCInterfaceIndexer: @unchecked Sendable {

    // MARK: - Upstream Indexer

    /// The upstream `MachOObjCSection` indexer. Exposed (`internal`) because
    /// `RuntimeObjCSection` hands it to `ObjCInterfaceBuilder` for interface
    /// generation; this wrapper only *adds* the relationship layer, it does not
    /// hide `upstream`. Mirrors `RuntimeSwiftInterfaceIndexer.upstream`, which
    /// `RuntimeSwiftSection` likewise passes to the generic specializer.
    ///
    /// Built in `init` and never reassigned — see the type's docs for why that
    /// matters here specifically.
    let upstream: ObjCInterfaceIndexer

    /// Transparent read-through to `upstream`: any property this wrapper does
    /// not declare itself resolves against `ObjCInterfaceIndexer`, so
    /// `RuntimeObjCSection` can treat the wrapper as its indexer for
    /// enumeration reads (`classNames`, `protocolNames`, `structNames`, …)
    /// without spelling out `.upstream`. Methods are not key-path-expressible,
    /// so the upstream methods the codebase needs are exposed as explicit
    /// wrapper methods below. Mirrors `RuntimeSwiftInterfaceIndexer`.
    subscript<Value>(dynamicMember keyPath: KeyPath<ObjCInterfaceIndexer, Value>) -> Value {
        upstream[keyPath: keyPath]
    }

    // MARK: - Relationship Reverse Tables

    /// The inheritance and protocol-adoption reverse tables for this image.
    ///
    /// A separate object rather than two `@Mutex` properties on `self`, because
    /// the event handler passed to `upstream`'s initializer has to capture the
    /// destination before `self` exists. This is the one structural difference
    /// from `RuntimeSwiftInterfaceIndexer`, which builds its tables after
    /// `upstream.prepare()` returns and so can store them inline.
    private let relationshipTables: RuntimeObjCRelationshipTables

    /// Per-image sub-indexers registered via `addSubIndexer`. Empty on a
    /// section's own indexer; on the `RuntimeObjCSectionFactory` aggregate it
    /// holds every loaded image's indexer, so the query methods fan out across
    /// all of them. `@Mutex`-guarded because the factory keeps registering and
    /// detaching as images load and unload. Mirrors
    /// `RuntimeSwiftInterfaceIndexer.subIndexers`.
    @Mutex
    private var subIndexers: [RuntimeObjCInterfaceIndexer] = []

    // MARK: - Init

    /// Build the upstream indexer for `machO` with the relationship handler
    /// already installed, and optionally forward `.progress` events to
    /// `progressContinuation`.
    ///
    /// The handler captures `relationshipTables` — never `self` — so it is
    /// fully formed before `upstream` exists and carries no retain cycle back
    /// into this object.
    init(machO: MachOImage, imagePath: String, progressContinuation: LoadingEventContinuation? = nil) {
        let relationshipTables = RuntimeObjCRelationshipTables()
        self.relationshipTables = relationshipTables
        self.upstream = ObjCInterfaceIndexer(
            machO: machO,
            imagePath: imagePath,
            eventHandler: { event in
                relationshipTables.fold(event)
                guard let progressContinuation,
                      case .progress(let phase, let itemDescription, let currentCount, let totalCount) = event
                else {
                    return
                }
                progressContinuation.yield(
                    RuntimeObjectsLoadingEvent.progress(
                        RuntimeObjectsLoadingProgress(
                            phase: phase.loadingPhase,
                            itemDescription: itemDescription,
                            currentCount: currentCount,
                            totalCount: totalCount
                        )
                    )
                )
            }
        )
    }

    // MARK: - Preparation

    /// Run the upstream extraction. The relationship tables fill *during* this
    /// call, from the handler installed in `init`, and are complete when it
    /// returns — there is no separate table-building step, and none to forget.
    ///
    /// Call once per indexer: the library replays its whole event stream on a
    /// second `prepare()`, which would double every relationship.
    func prepare() async throws {
        try await upstream.prepare()
    }

    // MARK: - Upstream Method Forwarding

    /// `@dynamicMemberLookup` forwards property *reads* only, so the upstream
    /// methods the codebase needs are wrapped explicitly. Mirrors
    /// `RuntimeSwiftInterfaceIndexer.updateConfiguration`.
    func classGroup(forName name: String) -> ObjCInterfaceIndexer.ObjCClassGroup? {
        upstream.classGroup(forName: name)
    }

    func protocolGroup(forName name: String) -> ObjCInterfaceIndexer.ObjCProtocolGroup? {
        upstream.protocolGroup(forName: name)
    }

    func categoryGroup(forName uniqueName: String) -> ObjCInterfaceIndexer.ObjCCategoryGroup? {
        upstream.categoryGroup(forName: uniqueName)
    }

    // MARK: - Relationship Query

    /// Direct subclasses of `className` — this indexer's own image plus every
    /// sub-indexer registered via `addSubIndexer`. On a per-image indexer (no
    /// sub-indexers) the result is just this image; on the factory aggregate it
    /// spans every loaded image. Per-image order follows the library's
    /// `__objc_classlist` walk; cross-image order follows registration order.
    func subclasses(of className: String) -> [RuntimeObjCClassReference] {
        var result = relationshipTables.subclasses(of: className)
        for subIndexer in subIndexers {
            for reference in subIndexer.subclasses(of: className) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    /// Classes adopting `protocolName` — inline adoptions first, then those
    /// contributed by categories, then the same from each registered
    /// sub-indexer.
    func conformingClasses(toProtocol protocolName: String) -> [RuntimeObjCClassReference] {
        var result = relationshipTables.conformingClasses(toProtocol: protocolName)
        for subIndexer in subIndexers {
            for reference in subIndexer.conformingClasses(toProtocol: protocolName) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    // MARK: - Aggregation

    /// Register a per-image indexer with this aggregate, so the query methods
    /// fan out into it. `RuntimeObjCSectionFactory` calls it as each section is
    /// created. Mirrors `RuntimeSwiftInterfaceIndexer.addSubIndexer(_:)`.
    func addSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer) {
        _subIndexers.withLock { $0.append(subIndexer) }
    }

    /// Detach a previously registered per-image indexer.
    ///
    /// **`addSubIndexer` without this is a leak, not an inconvenience.** The
    /// aggregate lives as long as its factory — i.e. as long as the owning
    /// `RuntimeEngine` — so a registration that is never undone pins that
    /// image's whole parsed index for the engine's lifetime, and
    /// `removeSection(for:)` reclaims nothing however carefully it drops its own
    /// entry. `RuntimeObjCSectionFactory.removeSection` / `removeAllSections`
    /// must call this *before* dropping the section.
    ///
    /// Identity comparison, not equality: two indexers over the same image are
    /// still two indexers.
    func removeSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer) {
        _subIndexers.withLock { subIndexers in
            subIndexers.removeAll { $0 === subIndexer }
        }
    }
}

// MARK: - Relationship Tables

/// The two reverse tables, folded from the indexer's event stream.
///
/// Split out of `RuntimeObjCInterfaceIndexer` so the event handler can capture
/// it before `self` exists. Being a type of its own also gives the folding
/// semantics somewhere to be tested directly: the three equivalence properties
/// are properties of `fold(_:)`, and a test that feeds it synthetic events
/// checks them without needing a real Mach-O image to parse. `internal` for
/// that reason; the tables themselves stay private to the indexer.
///
/// Two independent `@Mutex` properties rather than one lock over both: every
/// event touches exactly one of the tables, so there is no invariant spanning
/// them and nothing that needs to observe both at one instant.
///
/// `@unchecked Sendable`: both stored properties are `@Mutex`-guarded. The lock
/// is not optional — the library promises the *order* of events but explicitly
/// not the thread they arrive on, leaving room to parallelize the walk later.
final class RuntimeObjCRelationshipTables: @unchecked Sendable {

    @Mutex
    private var subclassesByClassName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]

    @Mutex
    private var conformingClassesByProtocolName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]

    init() {}

    // MARK: - Accumulation

    /// Fold one event into the tables. Progress events carry no table data and
    /// are ignored here — `RuntimeObjCInterfaceIndexer`'s handler forwards those
    /// separately.
    func fold(_ event: ObjCIndexingEvent) {
        switch event {
        case .progress:
            return

        case .subclassIndexed(let className, let superclass, let imagePath, let isSwiftStable):
            let reference = RuntimeObjCClassReference(
                className: className,
                imagePath: imagePath,
                isSwiftStable: isSwiftStable
            )
            _subclassesByClassName.withLock { $0[superclass, default: []].append(reference) }

        case .conformanceIndexed(let className, let protocolName, let imagePath, let isSwiftStable):
            let reference = RuntimeObjCClassReference(
                className: className,
                imagePath: imagePath,
                isSwiftStable: isSwiftStable
            )
            _conformingClassesByProtocolName.withLock { $0[protocolName, default: []].append(reference) }

        case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable):
            // `imagePath` is the image declaring the *category*, not the one
            // declaring `targetClassName`. Preserved verbatim: it is what the
            // library's table recorded, and changing it is a behaviour change.
            let reference = RuntimeObjCClassReference(
                className: targetClassName,
                imagePath: imagePath,
                isSwiftStable: targetIsSwiftStable
            )
            _conformingClassesByProtocolName.withLock { $0[protocolName, default: []].append(reference) }
        }
    }

    // MARK: - Query

    func subclasses(of className: String) -> OrderedSet<RuntimeObjCClassReference> {
        subclassesByClassName[className] ?? []
    }

    func conformingClasses(toProtocol protocolName: String) -> OrderedSet<RuntimeObjCClassReference> {
        conformingClassesByProtocolName[protocolName] ?? []
    }
}
