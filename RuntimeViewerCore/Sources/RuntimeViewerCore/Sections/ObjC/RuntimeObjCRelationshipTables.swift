import Foundation
import FoundationToolbox
import MachOKit
import ObjCIndexing
import OrderedCollections

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
/// `fold(_:)` mutates them through plain subscript assignment rather than
/// `withLock`. That is not a shortcut: `@Mutex` generates a `_modify` accessor
/// which locks, yields the storage inout, and unlocks in a `defer`, so the whole
/// read-modify-write of `table[key, default: []].append(…)` happens inside the
/// critical section. Wrapping it in `withLock` as well would take the lock
/// twice — and, because `OrderedSet.append` returns `(inserted:index:)`, would
/// hand back a value nobody wants, which is what the compiler was warning about.
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
            subclassesByClassName[superclass, default: []].append(reference)

        case .conformanceIndexed(let className, let protocolName, let imagePath, let isSwiftStable):
            let reference = RuntimeObjCClassReference(
                className: className,
                imagePath: imagePath,
                isSwiftStable: isSwiftStable
            )
            conformingClassesByProtocolName[protocolName, default: []].append(reference)

        case .categoryConformanceIndexed(let targetClassName, let protocolName, let imagePath, let targetIsSwiftStable):
            // `imagePath` is the image declaring the *category*, not the one
            // declaring `targetClassName`. Preserved verbatim: it is what the
            // library's table recorded, and changing it is a behaviour change.
            let reference = RuntimeObjCClassReference(
                className: targetClassName,
                imagePath: imagePath,
                isSwiftStable: targetIsSwiftStable
            )
            conformingClassesByProtocolName[protocolName, default: []].append(reference)
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
