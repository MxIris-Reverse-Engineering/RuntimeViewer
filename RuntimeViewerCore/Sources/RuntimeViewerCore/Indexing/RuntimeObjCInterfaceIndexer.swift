import Foundation
import SwiftStdlibToolbox
import OrderedCollections

/// A reference to an Objective-C class (or a Swift class that surfaces a
/// `class_t` record through `__objc_classlist`) that was found to subclass
/// another class or to adopt a protocol.
///
/// `isSwiftStable` carries the structural signal that lets `RuntimeEngine`
/// decide whether to materialize the reference as a Swift `RuntimeObject`
/// (kind `.swift(.type(.class))`) or as an Objective-C one
/// (kind `.objc(.type(.class))`). Mirrors the same field that
/// `RuntimeObjCSection.allObjects()` already uses to mark bridged classes.
public struct ObjCClassReference: Hashable, Sendable, Codable {
    public let className: String
    public let imagePath: String
    public let isSwiftStable: Bool

    public init(className: String, imagePath: String, isSwiftStable: Bool) {
        self.className = className
        self.imagePath = imagePath
        self.isSwiftStable = isSwiftStable
    }
}

/// Indexer for Objective-C inheritance (class -> direct subclasses) and
/// protocol-adoption (protocol -> classes that adopt it) relationships
/// within a single Mach-O image, plus aggregation across per-image
/// instances via `addSubIndexer`.
///
/// Mirrors `SwiftInterfaceIndexer` in shape: each `RuntimeObjCSection` owns a
/// `nonisolated let` per-image instance, and `RuntimeObjCSectionFactory`
/// owns the aggregate that holds every per-image indexer as a sub-indexer.
///
/// The indexer is intentionally not parameterised over a MachO type — unlike
/// `SwiftInterfaceIndexer`, this one is fed with already-extracted high-level
/// data (`ObjCClassInfo`-derived names) by `RuntimeObjCSection.prepare()`
/// and never touches Mach-O internals itself, so a MachO type parameter
/// would be pure phantom decoration.
public final class RuntimeObjCInterfaceIndexer: Sendable {

    @Mutex
    private var subclassesByClassName: [String: OrderedSet<ObjCClassReference>] = [:]

    @Mutex
    private var conformingClassesByProtocolName: [String: OrderedSet<ObjCClassReference>] = [:]

    @Mutex
    private var subIndexers: [RuntimeObjCInterfaceIndexer] = []

    private let eventHandler: RuntimeObjCInterfaceEvents.Handler?

    public init(eventHandler: RuntimeObjCInterfaceEvents.Handler? = nil) {
        self.eventHandler = eventHandler
    }

    // MARK: - Per-image Feed

    /// Records one Objective-C class record from `__objc_classlist`:
    ///   - its superclass name -> add this class as a subclass entry
    ///   - each protocol it adopts inline -> add this class as a conformer
    ///
    /// `__objc_classlist` automatically contains a `class_t` record for every
    /// Swift class with an Objective-C ancestor (`class Foo: NSObject`,
    /// whether or not annotated `@objc`). Pass `isSwiftStable: true` for those
    /// so the engine can materialize the reference as a Swift `RuntimeObject`
    /// at query time without doing any string-name bridging.
    public func indexClass(
        className: String,
        superClassName: String?,
        adoptedProtocolNames: [String],
        imagePath: String,
        isSwiftStable: Bool
    ) {
        let reference = ObjCClassReference(
            className: className,
            imagePath: imagePath,
            isSwiftStable: isSwiftStable
        )

        if let superClassName, !superClassName.isEmpty {
            _subclassesByClassName.withLock { dictionary in
                dictionary[superClassName, default: []].append(reference)
            }
            eventHandler?(
                RuntimeObjCInterfaceEvents.Event(
                    kind: .subclassIndexed(
                        className: className,
                        superclass: superClassName,
                        imagePath: imagePath
                    )
                )
            )
        }

        for protocolName in adoptedProtocolNames {
            _conformingClassesByProtocolName.withLock { dictionary in
                dictionary[protocolName, default: []].append(reference)
            }
            eventHandler?(
                RuntimeObjCInterfaceEvents.Event(
                    kind: .conformanceIndexed(
                        className: className,
                        protocolName: protocolName,
                        imagePath: imagePath
                    )
                )
            )
        }
    }

    /// Records one Objective-C category. Categories extend the conformance
    /// set of the target class: every protocol the category adopts gets the
    /// target class added as a conformer (with the target's `isSwiftStable`
    /// flag carried through, so a category on a bridged class still surfaces
    /// the class as Swift).
    public func indexCategory(
        targetClassName: String,
        targetIsSwiftStable: Bool,
        adoptedProtocolNames: [String],
        imagePath: String
    ) {
        let reference = ObjCClassReference(
            className: targetClassName,
            imagePath: imagePath,
            isSwiftStable: targetIsSwiftStable
        )

        for protocolName in adoptedProtocolNames {
            _conformingClassesByProtocolName.withLock { dictionary in
                dictionary[protocolName, default: []].append(reference)
            }
            eventHandler?(
                RuntimeObjCInterfaceEvents.Event(
                    kind: .categoryConformanceIndexed(
                        targetClassName: targetClassName,
                        protocolName: protocolName,
                        imagePath: imagePath
                    )
                )
            )
        }
    }

    // MARK: - Query

    /// All directly subclassing references for the given Objective-C class
    /// name, gathered from this indexer's own per-image data plus every
    /// sub-indexer registered via `addSubIndexer`. Insertion order is
    /// preserved across a single image; cross-image order follows
    /// `subIndexers` registration order.
    public func subclasses(of className: String) -> [ObjCClassReference] {
        var result: OrderedSet<ObjCClassReference> = subclassesByClassName[className] ?? []
        for subIndexer in subIndexers {
            for reference in subIndexer.subclasses(of: className) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    /// All classes (across all sub-indexers) that adopt the given protocol
    /// either inline (`@interface … <P>`) or via a category that adopts the
    /// protocol on the class.
    public func conformingClasses(toProtocol protocolName: String) -> [ObjCClassReference] {
        var result: OrderedSet<ObjCClassReference> = conformingClassesByProtocolName[protocolName] ?? []
        for subIndexer in subIndexers {
            for reference in subIndexer.conformingClasses(toProtocol: protocolName) {
                result.append(reference)
            }
        }
        return Array(result)
    }

    // MARK: - Aggregation

    /// Registers a per-image indexer with this aggregate. Mirrors
    /// `SwiftInterfaceIndexer.addSubIndexer(_:)` and is called by
    /// `RuntimeObjCSectionFactory` immediately after a new per-image
    /// `RuntimeObjCSection` has been constructed.
    public func addSubIndexer(_ subIndexer: RuntimeObjCInterfaceIndexer) {
        _subIndexers.withLock { $0.append(subIndexer) }
    }
}

// MARK: - Events

public enum RuntimeObjCInterfaceEvents {
    public struct Event: Sendable {
        public enum Kind: Sendable {
            case subclassIndexed(className: String, superclass: String, imagePath: String)
            case conformanceIndexed(className: String, protocolName: String, imagePath: String)
            case categoryConformanceIndexed(targetClassName: String, protocolName: String, imagePath: String)
        }

        public let kind: Kind

        public init(kind: Kind) {
            self.kind = kind
        }
    }

    public typealias Handler = @Sendable (Event) -> Void
}
