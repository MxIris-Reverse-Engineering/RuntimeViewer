import Foundation
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
import Semantic
import SwiftStdlibToolbox

/// A reference to an Objective-C class (or a Swift class that surfaces a
/// `class_t` record through `__objc_classlist`) that was found to subclass
/// another class or to adopt a protocol.
///
/// `isSwiftStable` carries the structural signal that lets
/// `RuntimeRelationshipsResolver` decide whether to materialize the
/// reference as a Swift `RuntimeObject` (kind `.swift(.type(.class))`) or as
/// an Objective-C one (kind `.objc(.type(.class))`). Mirrors the same field
/// that `RuntimeObjCSection.allObjects()` already uses to mark bridged classes.
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

/// Per-image Objective-C interface index: the parsed data store for one
/// Mach-O image's classes, protocols, categories and C struct/union
/// definitions, plus the class-inheritance and protocol-adoption reverse
/// tables that back `RuntimeRelationshipsResolver`.
///
/// This is the Objective-C counterpart of `SwiftInterfaceIndexer` on the
/// Swift side: it takes the image's `MachOImage` at `init` and owns *all*
/// of the raw `MachOObjCSection` / `ObjCDump` extraction (`prepare()`), so
/// `RuntimeObjCSection` is left as a thin translation layer that turns this
/// index into `RuntimeViewerCore` domain types (`RuntimeObject`,
/// `RuntimeObjectInterface`, `RuntimeMemberAddress`).
///
/// Aggregation: a `RuntimeObjCSectionFactory` keeps one empty aggregate
/// instance and registers every per-image indexer as a sub-indexer via
/// `addSubIndexer(_:)`, so relationship queries can fan out across all
/// loaded ObjC images. Mirrors `SwiftInterfaceIndexer.addSubIndexer(_:)`.
///
/// `@unchecked Sendable`: the `MachOImage` supplied at `init` and the
/// stored `ObjCDump` / `MachOObjCSection` values are not themselves
/// `Sendable`, but `machO` is an immutable `let` and every dictionary is
/// `@Mutex`-guarded and immutable once `prepare()` returns — mirroring the
/// `SwiftInterfaceIndexer` reference-type indexer pattern (a shared
/// `Sendable` data store), though the exact isolation annotations on each
/// side differ.
public final class RuntimeObjCInterfaceIndexer: @unchecked Sendable {

    // MARK: - Group Types

    /// A class paired with its own `ObjCClassInfo` plus the `ObjCClassInfo`
    /// of every superclass (resolved across images), `info.first` being the
    /// class itself. `internal` so `RuntimeObjCSection` can read the tuple.
    typealias ObjCClassGroup = (objcClass: any ObjCClassProtocol, info: [ObjCClassInfo])

    typealias ObjCProtocolGroup = (objcProtocol: any ObjCProtocolProtocol, info: ObjCProtocolInfo)

    typealias ObjCCategoryGroup = (objcCategory: any ObjCCategoryProtocol, info: ObjCCategoryInfo)

    // MARK: - C Struct / Union

    /// A C `struct` / `union` definition harvested from the ivar / method /
    /// property type encodings of the image's ObjC metadata.
    private struct CStructOrUnion: Hashable {
        let name: String

        let fields: [ObjCField]

        var hasBitFieldOnly: Bool {
            fields.allSatisfy { $0.bitWidth != nil }
        }

        var numberOfHasNameFields: Int {
            fields.count { $0.name != nil }
        }

        @SemanticStringBuilder
        func semanticString(isStruct: Bool, context: ObjCDumpContext) -> SemanticString {
            Keyword(isStruct ? "struct" : "union")
            Space()
            TypeName(kind: .other, name)
            Joined {
                MemberList(level: 1) {
                    for (index, field) in fields.enumerated() {
                        field.semanticString(fallbackName: "x\(index)", level: 1, context: context)
                    }
                }
            } prefix: {
                " {"
            } suffix: {
                Indent(level: 0)
                "}"
            }
        }
    }

    // MARK: - Indexed Image

    /// The Mach-O image this indexer parses. Bound at `init` and never
    /// reassigned — mirrors `SwiftInterfaceIndexer`, which likewise binds
    /// its `MachOImage` at construction. `prepare()` reads it to populate
    /// the data store below.
    private let machO: MachOImage

    /// The image path recorded into every `ObjCClassReference` and
    /// translated `RuntimeObject`. Passed explicitly rather than derived
    /// from `machO.imagePath`: `RuntimeObjCSection` may be constructed from
    /// a path that differs from the resolved image's own path — e.g. in
    /// Debug builds the main-executable stub path resolves to a sibling
    /// `.debug.dylib` image whose `imagePath` is not the stub's.
    private let imagePath: String

    // MARK: - Interface Data Store

    @Mutex
    private var classes: [String: ObjCClassGroup] = [:]

    @Mutex
    private var protocols: [String: ObjCProtocolGroup] = [:]

    @Mutex
    private var categories: [String: ObjCCategoryGroup] = [:]

    @Mutex
    private var structs: [String: CStructOrUnion] = [:]

    @Mutex
    private var unions: [String: CStructOrUnion] = [:]

    // MARK: - Relationship Reverse Tables

    @Mutex
    private var subclassesByClassName: [String: OrderedSet<ObjCClassReference>] = [:]

    @Mutex
    private var conformingClassesByProtocolName: [String: OrderedSet<ObjCClassReference>] = [:]

    @Mutex
    private var subIndexers: [RuntimeObjCInterfaceIndexer] = []

    private let eventHandler: RuntimeObjCInterfaceEvents.Handler?

    /// `internal`, not `public`: the parameter type `MachOImage` comes from
    /// a non-`public` import, and every construction site
    /// (`RuntimeObjCSection`, `RuntimeObjCSectionFactory`) lives in this
    /// module anyway. `prepare()` is likewise `internal`.
    init(machO: MachOImage, imagePath: String, eventHandler: RuntimeObjCInterfaceEvents.Handler? = nil) {
        self.machO = machO
        self.imagePath = imagePath
        self.eventHandler = eventHandler
    }

    // MARK: - Preparation

    /// Parse this indexer's Mach-O image (`machO`, bound at `init`) into the
    /// data store: every class / protocol / category, the C struct / union
    /// definitions harvested from their type encodings, and — inline as the
    /// `__objc_classlist` walk proceeds — the class-inheritance and
    /// protocol-adoption reverse tables.
    ///
    /// Called once by `RuntimeObjCSection.init`, after which the store is
    /// immutable. The aggregate indexer held by `RuntimeObjCSectionFactory`
    /// never calls this — it only aggregates per-image sub-indexers.
    func prepare(progressContinuation: LoadingEventContinuation? = nil) async throws {
        var classByName: [String: ObjCClassGroup] = [:]
        var protocolByName: [String: ObjCProtocolGroup] = [:]
        var categoryByName: [String: ObjCCategoryGroup] = [:]
        var structsByName: [String: CStructOrUnion] = [:]
        var unionsByName: [String: CStructOrUnion] = [:]
        var classInfoCache: [String: ObjCClassInfo] = [:]

        func setObjCType(_ type: ObjCType) {
            switch type {
            case .struct(let name, let fields):
                if let name {
                    let newStruct = CStructOrUnion(name: name, fields: fields ?? [])
                    guard !newStruct.hasBitFieldOnly else { return }
                    if let existStruct = structsByName[name] {
                        if existStruct.numberOfHasNameFields < newStruct.numberOfHasNameFields {
                            structsByName[name] = newStruct
                        }
                    } else {
                        structsByName[name] = newStruct
                    }
                }
            case .union(let name, let fields):
                if let name {
                    let newUnion = CStructOrUnion(name: name, fields: fields ?? [])
                    guard !newUnion.hasBitFieldOnly else { return }
                    if let existUnion = unionsByName[name] {
                        if existUnion.numberOfHasNameFields < newUnion.numberOfHasNameFields {
                            unionsByName[name] = newUnion
                        }
                    } else {
                        unionsByName[name] = newUnion
                    }
                }
            default:
                break
            }
        }

        func setObjCTypeFromMethods(_ methods: [ObjCMethodInfo]) {
            for method in methods {
                if let returnType = method.returnType {
                    setObjCType(returnType)
                }

                if let argumentInfos = method.argumentInfos {
                    for argumentInfo in argumentInfos {
                        setObjCType(argumentInfo.type)
                    }
                }
            }
        }

        func setObjCTypeFromProperties(_ properties: [ObjCPropertyInfo]) {
            for property in properties {
                for attribute in property.attributes {
                    if let type = attribute.type {
                        setObjCType(type)
                    }
                }
            }
        }

        let objcClasses: [any ObjCClassProtocol] = machO.objc.classes64.orEmpty + machO.objc.classes32.orEmpty + machO.objc.nonLazyClasses64.orEmpty + machO.objc.nonLazyClasses32.orEmpty

        // One-shot progress marker so the loading indicator can surface
        // "Indexing Objective-C subclasses…" before the per-class loop
        // starts pushing `.loadingObjCClasses` updates. Inheritance and
        // protocol-adoption indexing happens inline below — every class in
        // `__objc_classlist` (including Swift-derived ones via the same
        // record format) is fed to the reverse tables as we walk the list.
        progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
            phase: .indexingObjCSubclasses,
            itemDescription: "",
            currentCount: 0,
            totalCount: objcClasses.count
        )))

        for objcClass in objcClasses {
            let objcClassGroup: ObjCClassGroup = (objcClass, infoWithSuperclasses(class: objcClass, in: machO, cache: &classInfoCache))
            guard let objcClassInfo = objcClassGroup.info.first else { continue }
            classByName[objcClassInfo.name] = objcClassGroup
            progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCClasses,
                itemDescription: objcClassInfo.name,
                currentCount: classByName.count,
                totalCount: objcClasses.count
            )))

            // Feed the reverse tables. We pass the already-extracted class
            // info — `superClassName` is resolved through MachO's bind/rebase
            // walking by `infoWithSuperclasses`, so we don't redo that work
            // here. `isSwiftStable` comes off the raw class_t record itself,
            // exactly matching the field used by `RuntimeObjCSection` to mark
            // bridged classes' `secondaryKind`.
            indexClass(
                className: objcClassInfo.name,
                superClassName: objcClassInfo.superClassName,
                adoptedProtocolNames: objcClassInfo.protocols.map(\.name),
                imagePath: imagePath,
                isSwiftStable: objcClass.isSwiftStable
            )

            for ivar in objcClassInfo.ivars {
                if let type = ivar.type {
                    setObjCType(type)
                }
            }

            setObjCTypeFromProperties(objcClassInfo.properties + objcClassInfo.classProperties)
            setObjCTypeFromMethods(objcClassInfo.methods + objcClassInfo.classMethods)
        }

        let objcProtocols: [any ObjCProtocolProtocol] = machO.objc.protocols64.orEmpty + machO.objc.protocols32.orEmpty

        for objcProtocol in objcProtocols {
            guard let objcProtocolInfo = objcProtocol.info(in: machO) else { continue }
            protocolByName[objcProtocolInfo.name] = (objcProtocol, objcProtocolInfo)
            progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCProtocols,
                itemDescription: objcProtocolInfo.name,
                currentCount: protocolByName.count,
                totalCount: objcProtocols.count
            )))
            setObjCTypeFromProperties(objcProtocolInfo.properties + objcProtocolInfo.classProperties)
            setObjCTypeFromMethods(objcProtocolInfo.methods + objcProtocolInfo.classMethods)
        }

        var objcCategories: [any ObjCCategoryProtocol] = []

        objcCategories.append(contentsOf: machO.objc.categories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_32.orEmpty)

        // One-shot marker that conformance indexing starts; each category
        // extends the conformer set of its target class for every protocol
        // the category adopts.
        progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
            phase: .indexingObjCConformances,
            itemDescription: "",
            currentCount: 0,
            totalCount: objcCategories.count
        )))

        for objcCategory in objcCategories {
            guard let objcCategoryInfo = objcCategory.info(in: machO) else { continue }
            categoryByName[objcCategoryInfo.uniqueName] = (objcCategory, objcCategoryInfo)
            progressContinuation?.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCCategories,
                itemDescription: objcCategoryInfo.uniqueName,
                currentCount: categoryByName.count,
                totalCount: objcCategories.count
            )))
            setObjCTypeFromProperties(objcCategoryInfo.properties + objcCategoryInfo.classProperties)
            setObjCTypeFromMethods(objcCategoryInfo.methods + objcCategoryInfo.classMethods)

            // Feed category data to the reverse tables. The target class'
            // Swift stable flag is read from the already-resolved class
            // record so category adoptions on bridged classes (e.g. NSError
            // extending Swift error protocols) carry `isSwiftStable == true`
            // and surface as Swift `RuntimeObject` at query time.
            let targetClassName = objcCategoryInfo.className
            let targetIsSwiftStable: Bool
            if let (_, targetClass) = objcCategory.class(in: machO) {
                targetIsSwiftStable = targetClass.isSwiftStable
            } else {
                targetIsSwiftStable = false
            }
            indexCategory(
                targetClassName: targetClassName,
                targetIsSwiftStable: targetIsSwiftStable,
                adoptedProtocolNames: objcCategoryInfo.protocols.map(\.name),
                imagePath: imagePath
            )
        }

        classes = classByName
        protocols = protocolByName
        categories = categoryByName
        structs = structsByName
        unions = unionsByName
    }

    /// Resolve `cls` to its own `ObjCClassInfo` followed by the
    /// `ObjCClassInfo` of every superclass, walking `superClass(in:)` across
    /// image boundaries. `cache` memoizes `info(in:)` extraction so a deep
    /// inheritance chain shared by many classes is decoded only once.
    private func infoWithSuperclasses<Class: ObjCClassProtocol>(class cls: Class, in machO: MachOImage, cache: inout [String: ObjCClassInfo]) -> [ObjCClassInfo] {
        guard let className = cls.name(in: machO) else { return [] }

        var currentInfo: ObjCClassInfo?

        if let cacheInfo = cache[className] {
            currentInfo = cacheInfo
        } else {
            let info = cls.info(in: machO)
            currentInfo = info
            cache[className] = info
        }

        guard let currentInfo else { return [] }

        var resultInfos: [ObjCClassInfo] = [currentInfo]

        var machOAndSuperclass = cls.superClass(in: machO)

        while let currentMachOAndSuperclass = machOAndSuperclass {
            let currentMachO = currentMachOAndSuperclass.0
            let currentSuperclass = currentMachOAndSuperclass.1

            machOAndSuperclass = currentSuperclass.superClass(in: currentMachO)

            guard let superClassName = currentSuperclass.name(in: currentMachO) else { continue }

            var superclassInfo: ObjCClassInfo?
            if let cacheInfo = cache[superClassName] {
                superclassInfo = cacheInfo
            } else {
                let info = currentSuperclass.info(in: currentMachO)
                superclassInfo = info
                cache[superClassName] = info
            }
            if let superclassInfo {
                resultInfos.append(superclassInfo)
            }
        }

        return resultInfos
    }

    // MARK: - Reverse-table Feed

    /// Records one Objective-C class record from `__objc_classlist`:
    ///   - its superclass name -> add this class as a subclass entry
    ///   - each protocol it adopts inline -> add this class as a conformer
    ///
    /// `__objc_classlist` automatically contains a `class_t` record for every
    /// Swift class with an Objective-C ancestor (`class Foo: NSObject`,
    /// whether or not annotated `@objc`). Pass `isSwiftStable: true` for those
    /// so the resolver can materialize the reference as a Swift `RuntimeObject`
    /// at query time without doing any string-name bridging.
    private func indexClass(
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
            // `_ =` drops `OrderedSet.append`'s `(inserted:index:)` tuple so
            // the `withLock` closure stays `Void`-returning; a repeated
            // reference being deduped by `OrderedSet` is the intended behavior.
            _subclassesByClassName.withLock { dictionary in
                _ = dictionary[superClassName, default: []].append(reference)
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
                _ = dictionary[protocolName, default: []].append(reference)
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
    private func indexCategory(
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
                _ = dictionary[protocolName, default: []].append(reference)
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

    // MARK: - Interface Query

    /// The class plus its superclass chain for `name`, or `nil` if `name` is
    /// not a class in this image. `info.first` is the class itself.
    func classGroup(forName name: String) -> ObjCClassGroup? {
        classes[name]
    }

    /// The protocol record for `name`, or `nil` if `name` is not a protocol
    /// in this image.
    func protocolGroup(forName name: String) -> ObjCProtocolGroup? {
        protocols[name]
    }

    /// The category record for `uniqueName`, or `nil` if absent.
    func categoryGroup(forName uniqueName: String) -> ObjCCategoryGroup? {
        categories[uniqueName]
    }

    /// Names of every class in this image (`__objc_classlist` order is not
    /// preserved — dictionary iteration order).
    var classNames: [String] {
        Array(classes.keys)
    }

    var protocolNames: [String] {
        Array(protocols.keys)
    }

    var categoryNames: [String] {
        Array(categories.keys)
    }

    var structNames: [String] {
        Array(structs.keys)
    }

    var unionNames: [String] {
        Array(unions.keys)
    }

    /// Whether a C `struct` named `name` was harvested from this image —
    /// used by `ObjCDumpContext` to decide whether a referenced struct
    /// should be emitted inline or left as a forward declaration.
    func containsStruct(named name: String) -> Bool {
        structs[name] != nil
    }

    func containsUnion(named name: String) -> Bool {
        unions[name] != nil
    }

    /// The rendered interface of the C `struct` named `name`, or `nil` if
    /// absent. The `context` is supplied by `RuntimeObjCSection` because it
    /// depends on per-request generation options.
    func structSemanticString(forName name: String, context: ObjCDumpContext) -> SemanticString? {
        structs[name]?.semanticString(isStruct: true, context: context)
    }

    func unionSemanticString(forName name: String, context: ObjCDumpContext) -> SemanticString? {
        unions[name]?.semanticString(isStruct: false, context: context)
    }

    // MARK: - Relationship Query

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
