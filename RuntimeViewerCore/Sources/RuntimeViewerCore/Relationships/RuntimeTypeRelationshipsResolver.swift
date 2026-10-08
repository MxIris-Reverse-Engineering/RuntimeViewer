import Demangling
import Foundation
import FoundationToolbox
import OrderedCollections
import SwiftDeclaration

/// The Find navigator's relationship views — Ancestor Types, Descendant
/// Types, Conforming Types — as trees over every indexed image.
///
/// Sits beside `RuntimeRelationshipsResolver`, which answers the one-level
/// questions the Inspector asks (direct subclasses, direct conformers), and
/// reuses it for exactly those two. What this resolver adds is the walk:
/// superclass chains, adopted and refined protocols, transitive subclasses
/// and refinements, each level nested under the one before, with the
/// language boundary crossed wherever the metadata crosses it — a Swift class
/// whose superclass is `NSView`, a Swift protocol refining `NSObjectProtocol`.
///
/// Every node names its type and carries the `RuntimeObject` for it when an
/// indexed image defines it. A type nothing indexed defines is still a node,
/// unresolved — a chain ending at `NSObject` shows `NSObject` even when
/// libobjc was never indexed.
///
/// The walk keeps the path from a tree's root to the node it is building
/// (`RelationshipWalkPath`), not a visited set per tree: a protocol reached
/// along two paths — `NSObject` under `NSItemProviderReading` and again under
/// the `NSObject` class — appears under both, the way Xcode lists it, while a
/// cycle along one path (only a corrupt image has one) is still cut, a depth
/// cap backs that up, and a cancelled task stops every further step.
///
/// Every image compiled against an Objective-C protocol carries a full copy
/// of it, and none of them owns it. A protocol is one candidate, and one node
/// on a level, however many images carry it; the copy a node stands for is
/// chosen the same way whatever order the images were indexed in
/// (`preferredCarrierImagePath(among:referencedFrom:imagePaths:)`).
///
/// A query limited to some images walks the same trees and then keeps only
/// those images' types and the nodes leading to them, a protocol counting as
/// theirs when any of them carries a copy; the type asked about is looked up
/// everywhere regardless.
@Loggable(.private)
actor RuntimeTypeRelationshipsResolver {
    static let maximumDepth = 64

    private let objcSectionFactory: RuntimeObjCSectionFactory

    private let swiftSectionFactory: RuntimeSwiftSectionFactory

    private let relationshipsResolver: RuntimeRelationshipsResolver

    init(
        objcSectionFactory: RuntimeObjCSectionFactory,
        swiftSectionFactory: RuntimeSwiftSectionFactory,
        relationshipsResolver: RuntimeRelationshipsResolver
    ) {
        self.objcSectionFactory = objcSectionFactory
        self.swiftSectionFactory = swiftSectionFactory
        self.relationshipsResolver = relationshipsResolver
    }

    // MARK: - Query

    /// Throws when the query is a regular expression that does not compile,
    /// and `CancellationError` when the task asking is cancelled — a walk cut
    /// short is never handed out as if it were the whole tree.
    func trees(for query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree] {
        let candidates = try await candidateTypes(matching: query)
        var trees: [RuntimeRelationshipTree] = []
        trees.reserveCapacity(candidates.count)
        for candidate in candidates {
            try Task.checkCancellation()
            let path = RelationshipWalkPath(root: identity(of: candidate))
            let nodes: [RuntimeRelationshipNode]
            switch query.relationship {
            case .ancestors:
                nodes = await ancestorNodes(of: candidate, path: path)
            case .descendants:
                nodes = await descendantNodes(of: candidate, path: path)
            case .conformers:
                nodes = await conformerNodes(of: candidate)
            }
            // A cancelled walk stops where it is and returns what it had
            // reached; throw rather than pass that off as the tree.
            try Task.checkCancellation()
            if let imagePaths = query.imagePaths {
                // A protocol copy outside the images moves onto a copy inside
                // them before the tree is cut down to them.
                let movedNodes = await movingObjCProtocolCopies(of: nodes, into: imagePaths)
                let keptNodes = Self.nodes(movedNodes, leadingInto: imagePaths)
                guard !keptNodes.isEmpty else { continue }
                trees.append(RuntimeRelationshipTree(root: candidate, nodes: keptNodes))
            } else {
                trees.append(RuntimeRelationshipTree(root: candidate, nodes: nodes))
            }
        }
        return trees
    }

    /// The nodes for types of `imagePaths`, and those leading to one: a node
    /// for another image's type, or for a type no indexed image defines,
    /// stays only for what it leads to.
    static func nodes(_ nodes: [RuntimeRelationshipNode], leadingInto imagePaths: Set<String>) -> [RuntimeRelationshipNode] {
        nodes.compactMap { node in
            let children = Self.nodes(node.children, leadingInto: imagePaths)
            let isInImages = node.object.map { imagePaths.contains($0.imagePath) } ?? false
            guard isInImages || !children.isEmpty else { return nil }
            return RuntimeRelationshipNode(name: node.name, object: node.object, children: children)
        }
    }

    /// The types whose name matches the query under its match style, those
    /// named by the query itself first, then by name. The match style runs
    /// over a type's own name, so `View` finds `SwiftUI.View` and the module
    /// or an enclosing type matches nothing by itself; a query with a dot in
    /// it runs over the qualified name (`RuntimeInterfaceTextMatcher
    /// .typeNameMatches(_:pattern:)`). A query limited to some images puts
    /// their types first among the exact matches and among the rest, so the
    /// candidate limit is spent on them before the types whose trees may
    /// have nothing left in those images.
    ///
    /// One candidate per type: an Objective-C protocol every carrying image
    /// lists a copy of is one candidate, and a Swift class registered with
    /// the Objective-C runtime is a candidate under its Swift face.
    private func candidateTypes(matching query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeObject] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: text, matchMode: query.matchMode, isCaseSensitive: query.isCaseSensitive)
        let options: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]

        var exactMatches: OrderedSet<RuntimeObject> = []
        var partialMatches: OrderedSet<RuntimeObject> = []
        // Every image compiled against an Objective-C protocol carries a copy
        // of it. The first copy found holds the protocol's place; which copy
        // the candidate stands for is decided once all of them are known.
        var objcProtocolCopiesByName: [String: [RuntimeObject]] = [:]
        func consider(_ object: RuntimeObject) {
            guard Self.isRelationshipCandidate(object),
                  RuntimeInterfaceTextMatcher.typeNameMatches(object.displayName, pattern: pattern)
            else { return }
            if object.kind == .objc(.type(.protocol)) {
                let isFirstCopy = objcProtocolCopiesByName[object.name] == nil
                objcProtocolCopiesByName[object.name, default: []].append(object)
                guard isFirstCopy else { return }
            }
            let ownName = RuntimeInterfaceTextMatcher.ownTypeName(of: object.displayName)
            if object.displayName.compare(text, options: options) == .orderedSame || ownName.compare(text, options: options) == .orderedSame {
                exactMatches.append(object)
            } else {
                partialMatches.append(object)
            }
        }
        func considerTree(_ object: RuntimeObject) {
            consider(object)
            for child in object.children {
                considerTree(child)
            }
        }

        // Every image costs a hop to its section, and `try?` below would read
        // a cancellation from underneath as "no objects", so the task is
        // checked here, once per image.
        for imagePath in await objcSectionFactory.cachedImagePaths.sorted() {
            try Task.checkCancellation()
            guard let section = await objcSectionFactory.existingSection(for: imagePath),
                  let objects = try? await section.allObjects()
            else { continue }
            objects.forEach(considerTree)
        }
        for imagePath in await swiftSectionFactory.cachedImagePaths.sorted() {
            try Task.checkCancellation()
            guard let section = await swiftSectionFactory.existingSection(for: imagePath),
                  let objects = try? await section.allObjects()
            else { continue }
            objects.forEach(considerTree)
        }
        try Task.checkCancellation()

        // A Swift face that matched as well keeps the spelling the sidebar
        // lists it under, whichever of its two faces came first.
        func listedObject(_ object: RuntimeObject) -> RuntimeObject {
            if let index = exactMatches.firstIndex(of: object) {
                return exactMatches[index]
            }
            if let index = partialMatches.firstIndex(of: object) {
                return partialMatches[index]
            }
            return object
        }
        // An exact match wins over a partial one standing for the same type.
        var representedExactMatches: OrderedSet<RuntimeObject> = []
        for object in exactMatches {
            representedExactMatches.append(listedObject(await representative(of: object, objcProtocolCopiesByName: objcProtocolCopiesByName, imagePaths: query.imagePaths)))
        }
        var representedPartialMatches: OrderedSet<RuntimeObject> = []
        for object in partialMatches {
            let representedObject = listedObject(await representative(of: object, objcProtocolCopiesByName: objcProtocolCopiesByName, imagePaths: query.imagePaths))
            guard !representedExactMatches.contains(representedObject) else { continue }
            representedPartialMatches.append(representedObject)
        }

        let sortedPartialMatches = representedPartialMatches.sorted { left, right in
            left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
        let candidates: [RuntimeObject]
        if let imagePaths = query.imagePaths {
            func inImagesFirst(_ objects: [RuntimeObject]) -> [RuntimeObject] {
                objects.filter { imagePaths.contains($0.imagePath) } + objects.filter { !imagePaths.contains($0.imagePath) }
            }
            candidates = inImagesFirst(Array(representedExactMatches)) + inImagesFirst(sortedPartialMatches)
        } else {
            candidates = Array(representedExactMatches) + sortedPartialMatches
        }
        return Array(candidates.prefix(max(0, query.candidateLimit)))
    }

    /// The object a candidate stands for: the chosen copy of an Objective-C
    /// protocol, and the Swift face of a Swift class registered with the
    /// Objective-C runtime — the face the sidebar, the Inspector and every
    /// node of the walk show. A class with no Swift face to pair it with
    /// keeps its Objective-C one, as `materializeObjCClass(named:)` does.
    private func representative(of object: RuntimeObject, objcProtocolCopiesByName: [String: [RuntimeObject]], imagePaths scopeImagePaths: Set<String>?) async -> RuntimeObject {
        switch object.kind {
        case .objc(.type(.protocol)):
            let copies = objcProtocolCopiesByName[object.name] ?? [object]
            let preferredImagePath = Self.preferredCarrierImagePath(among: copies.map(\.imagePath), referencedFrom: nil, imagePaths: scopeImagePaths)
            return copies.first { $0.imagePath == preferredImagePath } ?? object
        case .objc(.type(.class)) where object.properties.contains(.isSwiftClass):
            guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath),
                  let swiftFace = await swiftSection.makeRuntimeObject(forObjCRuntimeClassName: object.name)
            else { return object }
            return swiftFace
        default:
            return object
        }
    }

    /// Types with a place in a hierarchy: classes and protocols on both
    /// sides, plus Swift structs, enums and actors (they adopt protocols).
    /// Extensions, conformance listings, type aliases and C types are not.
    private static func isRelationshipCandidate(_ object: RuntimeObject) -> Bool {
        switch object.kind {
        case .objc(.type):
            return true
        case .swift(.type(let kind)):
            return kind != .typeAlias
        default:
            return false
        }
    }

    // MARK: - Ancestors

    /// `object`'s ancestors; `path` already ends at `object`.
    private func ancestorNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        switch object.kind {
        case .objc(.type(.class)):
            return await objcClassAncestorNodes(named: object.name, path: path)
        case .objc(.type(.protocol)):
            return await objcProtocolAncestorNodes(named: object.name, referencedFrom: object.imagePath, path: path)
        case .swift(.type(.protocol)):
            return await swiftProtocolAncestorNodes(qualifiedName: swiftProtocolQualifiedName(of: object), path: path)
        case .swift(.type):
            return await swiftTypeAncestorNodes(of: object, path: path)
        default:
            return []
        }
    }

    /// An Objective-C class's ancestors: the protocols it adopts, then its
    /// superclass carrying the same for itself, recursively — the shape
    /// Xcode nests them in.
    private func objcClassAncestorNodes(named className: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        guard let (group, classImagePath) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
              let classInfo = group.info.first
        else { return [] }
        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), referencedFrom: classImagePath, path: path)
        if let superclassName = classInfo.superClassName, !superclassName.isEmpty,
           let superclassPath = path.descending(into: .objcClass(name: superclassName)) {
            let superclass = await materializeObjCClass(named: superclassName)
            let children = await objcClassAncestorNodes(named: superclassName, path: superclassPath)
            nodes.append(RuntimeRelationshipNode(name: superclass?.displayName ?? superclassName, object: superclass, children: children))
        }
        return nodes
    }

    private func objcProtocolAncestorNodes(named protocolName: String, referencedFrom referencingImagePath: String?, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), referencedFrom: referencingImagePath, path: path)
    }

    /// Nodes for Objective-C protocols by name, each carrying the protocols
    /// it adopts underneath. `referencingImagePath` is the image whose
    /// metadata named them — the adopting class's, or the copy of the
    /// refining protocol a node stands for — and each node prefers that
    /// image's own copy. It changes from node to node, so it is passed along
    /// rather than kept in the path.
    private func objcProtocolNodes(named protocolNames: [String], referencedFrom referencingImagePath: String?, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        var nodes: [RuntimeRelationshipNode] = []
        for protocolName in protocolNames {
            guard let protocolPath = path.descending(into: .objcProtocol(name: protocolName)) else { continue }
            let object = await materializeObjCProtocol(named: protocolName, referencedFrom: referencingImagePath)
            let children = await objcProtocolAncestorNodes(named: protocolName, referencedFrom: object?.imagePath ?? referencingImagePath, path: protocolPath)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? protocolName, object: object, children: children))
        }
        return nodes
    }

    /// The Objective-C protocols a Swift class adopts. Adopting one leaves no
    /// Swift conformance record: it is written into the class's Objective-C
    /// face, where Conforming Types reads it, so Ancestor Types reads it
    /// there too. A class with no Objective-C face adopts none.
    private func objcProtocolNodes(adoptedBySwiftClass object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        guard let swiftSection = await swiftSectionFactory.existingSection(for: object.imagePath),
              let objcClassName = await swiftSection.objcClassName(forCounterpartOf: object),
              let objcSection = await objcSectionFactory.existingSection(for: object.imagePath),
              let classInfo = objcSection.objcIndexer.classGroup(forName: objcClassName)?.info.first
        else { return [] }
        return await objcProtocolNodes(named: classInfo.protocols.map(\.name), referencedFrom: object.imagePath, path: path)
    }

    /// A Swift struct's, enum's, actor's or class's ancestors: the protocols
    /// it conforms to — for a class, the Objective-C ones its Objective-C face
    /// adopts as well — then, for a class, its superclass with the same
    /// underneath. A superclass bound to generic arguments is the generic
    /// class itself. One no Swift image defines is looked up as an
    /// Objective-C class when it is an imported one, by the runtime name the
    /// indexer recorded, and is left unresolved otherwise.
    private func swiftTypeAncestorNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        let indexer = swiftSectionFactory.indexer
        var nodes = await swiftProtocolNodes(
            qualifiedNames: indexer.conformingProtocolNames(forMangledTypeName: object.name).map(\.name),
            path: path
        )
        if case .swift(.type(.class)) = object.kind {
            nodes += await objcProtocolNodes(adoptedBySwiftClass: object, path: path)
        }
        guard case .swift(.type(.class)) = object.kind,
              let superclassMangledName = indexer.superclassMangledName(forMangledTypeName: object.name)
        else { return nodes }

        if let superclass = await materializeSwiftType(mangledName: superclassMangledName) {
            guard let superclassPath = path.descending(into: .swiftType(mangledName: superclass.name)) else { return nodes }
            let children = await swiftTypeAncestorNodes(of: superclass, path: superclassPath)
            nodes.append(RuntimeRelationshipNode(object: superclass, children: children))
            return nodes
        }

        let displayName = indexer.superclassDisplayName(forMangledTypeName: object.name) ?? superclassMangledName
        if let objcClassName = indexer.superclassObjCClassName(forMangledTypeName: object.name),
           let objcSuperclass = await materializeObjCClass(named: objcClassName) {
            guard let superclassIdentity = identity(of: objcSuperclass),
                  let superclassPath = path.descending(into: superclassIdentity)
            else { return nodes }
            let children = await ancestorNodes(of: objcSuperclass, path: superclassPath)
            nodes.append(RuntimeRelationshipNode(object: objcSuperclass, children: children))
        } else {
            nodes.append(RuntimeRelationshipNode(name: displayName, object: nil, children: []))
        }
        return nodes
    }

    private func swiftProtocolAncestorNodes(qualifiedName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        let declaringImagePath = swiftSectionFactory.indexer.protocolReference(forQualifiedName: qualifiedName)?.imagePath
        var nodes: [RuntimeRelationshipNode] = []
        for refined in swiftSectionFactory.indexer.refinedProtocols(ofQualifiedName: qualifiedName) {
            if refined.isObjC {
                nodes += await objcProtocolNodes(named: [refined.qualifiedName], referencedFrom: declaringImagePath, path: path)
            } else {
                nodes += await swiftProtocolNodes(qualifiedNames: [refined.qualifiedName], path: path)
            }
        }
        return nodes
    }

    /// Nodes for Swift protocols by qualified name, each carrying the
    /// protocols it refines underneath.
    private func swiftProtocolNodes(qualifiedNames: [String], path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        var nodes: [RuntimeRelationshipNode] = []
        for qualifiedName in qualifiedNames {
            guard let protocolPath = path.descending(into: .swiftProtocol(qualifiedName: qualifiedName)) else { continue }
            let object = await materializeSwiftProtocol(qualifiedName: qualifiedName)
            let children = await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, path: protocolPath)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? qualifiedName, object: object, children: children))
        }
        return nodes
    }

    // MARK: - Descendants

    /// `object`'s descendants; `path` already ends at `object`.
    private func descendantNodes(of object: RuntimeObject, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        switch object.kind {
        case .objc(.type(.class)), .swift(.type(.class)):
            var nodes: [RuntimeRelationshipNode] = []
            for subclass in await relationshipsResolver.relationships(for: object).subclasses {
                guard let subclassIdentity = identity(of: subclass),
                      let subclassPath = path.descending(into: subclassIdentity)
                else { continue }
                let children = await descendantNodes(of: subclass, path: subclassPath)
                nodes.append(RuntimeRelationshipNode(object: subclass, children: children))
            }
            return nodes
        case .objc(.type(.protocol)):
            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, referencedFrom: object.imagePath, path: path)
        case .swift(.type(.protocol)):
            return await refiningProtocolNodes(ofSwiftProtocolNamed: swiftProtocolQualifiedName(of: object), path: path)
        default:
            return []
        }
    }

    /// The protocols refining an Objective-C protocol: Objective-C ones from
    /// the ObjC tables, and Swift ones — a Swift protocol may refine an
    /// Objective-C protocol — from the Swift tables, which key them by the
    /// same runtime name. Every image carrying a refining Objective-C
    /// protocol reports it, so one node stands for all of its copies — the
    /// copy of the image the parent node stands for when it carries one —
    /// and the level is listed by name.
    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, referencedFrom referencingImagePath: String?, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        var carrierImagePathsByProtocolName: OrderedDictionary<String, [String]> = [:]
        for reference in objcSectionFactory.indexer.refiningProtocols(of: protocolName) {
            carrierImagePathsByProtocolName[reference.protocolName, default: []].append(reference.imagePath)
        }
        var nodes: [RuntimeRelationshipNode] = []
        for (refiningProtocolName, carrierImagePaths) in carrierImagePathsByProtocolName {
            guard let protocolPath = path.descending(into: .objcProtocol(name: refiningProtocolName)),
                  let carrierImagePath = Self.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: referencingImagePath, imagePaths: nil)
            else { continue }
            let object = await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: refiningProtocolName)
            let children = await refiningProtocolNodes(ofObjCProtocolNamed: refiningProtocolName, referencedFrom: carrierImagePath, path: protocolPath)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? refiningProtocolName, object: object, children: children))
        }
        nodes += await swiftRefiningProtocolNodes(of: protocolName, path: path)
        return Self.sortedByName(nodes)
    }

    private func refiningProtocolNodes(ofSwiftProtocolNamed qualifiedName: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        await swiftRefiningProtocolNodes(of: qualifiedName, path: path)
    }

    private func swiftRefiningProtocolNodes(of name: String, path: RelationshipWalkPath) async -> [RuntimeRelationshipNode] {
        var nodes: [RuntimeRelationshipNode] = []
        for reference in swiftSectionFactory.indexer.refiningProtocols(ofQualifiedName: name) {
            guard let protocolPath = path.descending(into: .swiftProtocol(qualifiedName: reference.qualifiedName)) else { continue }
            let object = await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
            let children = await swiftRefiningProtocolNodes(of: reference.qualifiedName, path: protocolPath)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.qualifiedName, object: object, children: children))
        }
        return Self.sortedByName(nodes)
    }

    // MARK: - Conformers

    private func conformerNodes(of object: RuntimeObject) async -> [RuntimeRelationshipNode] {
        await relationshipsResolver.relationships(for: object).conformingTypes.map { RuntimeRelationshipNode(object: $0) }
    }

    // MARK: - Materialization

    /// The `RuntimeObject` for an Objective-C class from whichever indexed
    /// image declares it — as its Swift face when the class is a Swift class,
    /// the way the sidebar and the Inspector list it.
    ///
    /// Unlike `RuntimeRelationshipsResolver.materializeObjCReference(_:)`,
    /// which drops a Swift class whose Swift face it cannot find, this falls
    /// back to the Objective-C face, deliberately: a list loses one row to a
    /// dropped entry, but an ancestor chain would lose the superclass and
    /// everything above it, up to `NSObject` and the protocols on the way.
    /// Since the two faces are paired through the class object, a class goes
    /// unpaired only when its image has no Swift section, which
    /// `RuntimeEngine` never builds apart from the Objective-C one.
    private func materializeObjCClass(named className: String) async -> RuntimeObject? {
        guard let (group, imagePath) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className) else { return nil }
        if group.objcClass.isSwiftStable,
           let swiftSection = await swiftSectionFactory.existingSection(for: imagePath),
           let swiftObject = await swiftSection.makeRuntimeObject(forObjCRuntimeClassName: className) {
            return swiftObject
        }
        return await objcSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forClassName: className)
    }

    /// The `RuntimeObject` for the copy of an Objective-C protocol a node
    /// stands for; see `preferredCarrierImagePath(among:referencedFrom:imagePaths:)`.
    private func materializeObjCProtocol(named protocolName: String, referencedFrom referencingImagePath: String?) async -> RuntimeObject? {
        let carrierImagePaths = objcSectionFactory.indexer.protocolCarrierImagePaths(forName: protocolName)
        guard let carrierImagePath = Self.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: referencingImagePath, imagePaths: nil) else { return nil }
        return await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: protocolName)
    }

    private func materializeSwiftType(mangledName: String) async -> RuntimeObject? {
        guard let (_, imagePath) = swiftSectionFactory.indexer.typeDefinition(forMangledName: mangledName) else { return nil }
        return await swiftSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forMangledTypeName: mangledName)
    }

    private func materializeSwiftProtocol(qualifiedName: String) async -> RuntimeObject? {
        guard let reference = swiftSectionFactory.indexer.protocolReference(forQualifiedName: qualifiedName) else { return nil }
        return await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
    }

    // MARK: - Walk State

    /// The identity a materialized type is walked under, `nil` for kinds a
    /// walk never stands on.
    private func identity(of object: RuntimeObject) -> RelationshipTypeIdentity? {
        switch object.kind {
        case .objc(.type(.class)):
            return .objcClass(name: object.name)
        case .objc(.type(.protocol)):
            return .objcProtocol(name: object.name)
        case .swift(.type(.protocol)):
            return .swiftProtocol(qualifiedName: swiftProtocolQualifiedName(of: object))
        case .swift(.type):
            return .swiftType(mangledName: object.name)
        default:
            return nil
        }
    }

    /// The qualified name the Swift tables key a protocol by. One protocol
    /// arrives under more than one printed name — the sidebar lists a
    /// protocol nested in a type by its own short name — so it is recovered
    /// from the mangled name rather than read off `displayName`.
    private func swiftProtocolQualifiedName(of object: RuntimeObject) -> String {
        swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
    }

    /// One type a walk can stand on. A class and a protocol of one name are
    /// two types, and so are a Swift class and the Objective-C class it is
    /// registered as. Every step keys the path by this one value, so a cycle
    /// cannot slip past under a second spelling of the same type.
    private enum RelationshipTypeIdentity: Hashable {
        case objcClass(name: String)
        case objcProtocol(name: String)
        case swiftType(mangledName: String)
        case swiftProtocol(qualifiedName: String)
    }

    /// The path from a tree's root to the node being built: the types on it
    /// and how deep it runs. Siblings each descend from the same path, so a
    /// type reached along two paths shows under both, while a cycle along one
    /// — only a corrupt image has one — is cut, with the depth cap as the
    /// backstop. A cancelled task descends no further: the walk then returns
    /// what it had, and `trees(for:)` throws instead of handing that out.
    private struct RelationshipWalkPath {
        private var identities: Set<RelationshipTypeIdentity>

        private var depth: Int

        init(root: RelationshipTypeIdentity?) {
            if let root {
                identities = [root]
            } else {
                identities = []
            }
            depth = 0
        }

        /// The path one step further, onto `identity`; `nil` when that type
        /// is on the path already, when the path is as deep as a walk goes,
        /// or when the task asking has been cancelled.
        func descending(into identity: RelationshipTypeIdentity) -> RelationshipWalkPath? {
            guard depth < RuntimeTypeRelationshipsResolver.maximumDepth,
                  !Task.isCancelled,
                  !identities.contains(identity)
            else { return nil }
            var path = self
            path.identities.insert(identity)
            path.depth += 1
            return path
        }
    }

    // MARK: - Objective-C Protocol Copies

    /// The copy of an Objective-C protocol a node stands for. Every image
    /// compiled against a protocol carries a full copy and none of them owns
    /// it, so the choice only has to be stable — the same indexed images give
    /// the same copy whatever order they were indexed in: the copy of the
    /// image whose metadata named the protocol, when it carries one and the
    /// query's images do not leave it out; then the first copy by path among
    /// the query's images; then the first copy by path.
    static func preferredCarrierImagePath(among carrierImagePaths: [String], referencedFrom referencingImagePath: String?, imagePaths scopeImagePaths: Set<String>?) -> String? {
        if let referencingImagePath,
           carrierImagePaths.contains(referencingImagePath),
           scopeImagePaths?.contains(referencingImagePath) ?? true {
            return referencingImagePath
        }
        if let scopeImagePaths,
           let firstCarrierInScope = carrierImagePaths.filter({ scopeImagePaths.contains($0) }).min() {
            return firstCarrierInScope
        }
        return carrierImagePaths.min()
    }

    /// A query limited to some images counts an Objective-C protocol as
    /// theirs when any of them carries a copy, the way their sidebar lists
    /// it: a node standing for a copy outside them moves onto the first copy
    /// inside them, so cutting the tree down to them keeps it.
    private func movingObjCProtocolCopies(of nodes: [RuntimeRelationshipNode], into imagePaths: Set<String>) async -> [RuntimeRelationshipNode] {
        var movedNodes: [RuntimeRelationshipNode] = []
        movedNodes.reserveCapacity(nodes.count)
        for node in nodes {
            let children = await movingObjCProtocolCopies(of: node.children, into: imagePaths)
            var object = node.object
            if let protocolObject = node.object,
               protocolObject.kind == .objc(.type(.protocol)),
               !imagePaths.contains(protocolObject.imagePath),
               let carrierImagePath = Self.preferredCarrierImagePath(
                   among: objcSectionFactory.indexer.protocolCarrierImagePaths(forName: protocolObject.name),
                   referencedFrom: nil,
                   imagePaths: imagePaths
               ),
               imagePaths.contains(carrierImagePath),
               let movedObject = await objcSectionFactory.existingSection(for: carrierImagePath)?.makeRuntimeObject(forProtocolName: protocolObject.name) {
                object = movedObject
            }
            movedNodes.append(RuntimeRelationshipNode(name: node.name, object: object, children: children))
        }
        return movedNodes
    }

    /// A level of Descendent Types listed by name, the way the Inspector
    /// lists subclasses. Left alone it would follow the dictionary order of
    /// the library's protocol table, which changes with every launch, and
    /// the order the images were indexed in. Names that compare equal
    /// ignoring case fall back to their exact spelling, then to the kind.
    private static func sortedByName(_ nodes: [RuntimeRelationshipNode]) -> [RuntimeRelationshipNode] {
        nodes.sorted { left, right in
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            if left.name != right.name {
                return left.name < right.name
            }
            return String(describing: left.object?.kind) < String(describing: right.object?.kind)
        }
    }
}
