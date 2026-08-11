import Foundation
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

/// Per-image Objective-C relationship index: the inheritance and
/// protocol-adoption reverse tables backing the Inspector's Relationships pane.
///
/// MachOObjCSection 0003 removed these tables from `ObjCIndexing` — the library
/// parses and broadcasts what it finds, and no longer remembers how classes
/// relate. This is where those broadcasts become tables again.
///
/// ## Relationship data arrives only through the event stream
///
/// An instance is installed as the indexer's `eventHandler` *before*
/// `prepare()` runs and accumulates throughout the walk. An `ObjCInterfaceIndexer`
/// constructed without a handler keeps no relationship data at all, so
/// `RuntimeObjCSection` installs one unconditionally — never gated on whether a
/// progress stream happens to exist.
///
/// ## Tables are built on first query
///
/// `record(_:)` only appends; the tables are materialized lazily. There is
/// deliberately no "sealing" call the caller must remember to make: forgetting
/// it, or skipping it because `prepare()` threw, would leave the index
/// permanently empty *without any error* — the same silent-emptiness failure
/// this whole design exists to rule out. `prewarm()` is available to pay the
/// build cost up front, and is never required for correctness.
///
/// ## Equivalence with the library's former tables
///
/// Three properties of the old implementation are reproduced deliberately:
///
/// 1. Inline adoptions and category-contributed adoptions land in **one**
///    conformer table, so a single query returns both.
/// 2. Events are replayed from a **single** queue in arrival order, so inline
///    adoptions precede category ones exactly as they did when the library
///    walked classes before categories.
/// 3. `OrderedSet` deduplicates on all three fields, not on `className`. A class
///    can legitimately appear twice for one protocol with differing
///    `isSwiftStable` — inline adoption reads the class' own flag while a
///    category resolves its target across images and falls back to `false`.
///    Collapsing those would look like a bug fix and would be a behaviour change.
///
/// `@unchecked Sendable`: every stored property is guarded by `lock`.
final class RuntimeObjCRelationshipIndex: @unchecked Sendable {
    private struct Tables {
        var subclassesByClassName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]
        var conformingClassesByProtocolName: [String: OrderedSet<RuntimeObjCClassReference>] = [:]
    }

    private let lock = NSLock()

    /// Events in arrival order, awaiting replay. Cleared once `tables` is built.
    private var pendingEvents: [ObjCIndexingEvent] = []

    private var tables: Tables?

    init() {}

    // MARK: - Accumulation

    /// Append one event. Progress events are ignored; only the three
    /// relationship cases carry table data.
    ///
    /// A single `append` under the lock is all the work done on the parse hot
    /// path — cheaper than the two dictionary lookups plus `OrderedSet.append`
    /// the library used to perform here. The lock is required: the library
    /// promises the *order* of events but explicitly not the thread they arrive
    /// on, leaving room to parallelize the walk later.
    func record(_ event: ObjCIndexingEvent) {
        switch event {
        case .progress:
            return
        case .subclassIndexed, .conformanceIndexed, .categoryConformanceIndexed:
            lock.lock()
            defer { lock.unlock() }
            if tables != nil {
                // Already materialized — fold the event straight in rather than
                // invalidating, since `pendingEvents` was released at build time
                // and could no longer reproduce the earlier events. Arrival
                // order still holds: this event genuinely comes last.
                apply(event, into: &tables!)
            } else {
                pendingEvents.append(event)
            }
        }
    }

    /// Build the tables now rather than on first query. Optional: skipping it
    /// costs nothing but deferring the same work.
    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        _ = materializedTables()
    }

    // MARK: - Query

    /// Direct subclasses of `className` recorded for this image, in the order
    /// the library walked `__objc_classlist`.
    func subclasses(of className: String) -> [RuntimeObjCClassReference] {
        lock.lock()
        defer { lock.unlock() }
        return Array(materializedTables().subclassesByClassName[className] ?? [])
    }

    /// Classes adopting `protocolName` in this image — inline adoptions first,
    /// then those contributed by categories.
    func conformingClasses(toProtocol protocolName: String) -> [RuntimeObjCClassReference] {
        lock.lock()
        defer { lock.unlock() }
        return Array(materializedTables().conformingClassesByProtocolName[protocolName] ?? [])
    }

    // MARK: - Materialization

    /// Caller must hold `lock`.
    private func materializedTables() -> Tables {
        if let tables { return tables }

        var built = Tables()
        for event in pendingEvents {
            apply(event, into: &built)
        }

        tables = built
        pendingEvents = []
        return built
    }

    /// Fold one event into `tables`. Caller must hold `lock`.
    private func apply(_ event: ObjCIndexingEvent, into tables: inout Tables) {
        switch event {
        case .progress:
            return

        case .subclassIndexed(let className, let superclass, let imagePath, let isSwiftStable):
            let reference = RuntimeObjCClassReference(
                className: className,
                imagePath: imagePath,
                isSwiftStable: isSwiftStable
            )
            tables.subclassesByClassName[superclass, default: []].append(reference)

        case .conformanceIndexed(let className, let protocolName, let imagePath, let isSwiftStable):
            let reference = RuntimeObjCClassReference(
                className: className,
                imagePath: imagePath,
                isSwiftStable: isSwiftStable
            )
            tables.conformingClassesByProtocolName[protocolName, default: []].append(reference)

        case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable):
            // `imagePath` is the image declaring the *category*, not the one
            // declaring `targetClassName`. Preserved verbatim: it is what the
            // library's table recorded, and changing it is a behaviour change.
            let reference = RuntimeObjCClassReference(
                className: targetClassName,
                imagePath: imagePath,
                isSwiftStable: targetIsSwiftStable
            )
            tables.conformingClassesByProtocolName[protocolName, default: []].append(reference)
        }
    }
}
