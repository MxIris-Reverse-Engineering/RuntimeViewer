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
/// The visited set is per path, not per tree: a protocol reached along two
/// paths — `NSObject` under `NSItemProviderReading` and again under the
/// `NSObject` class — appears under both, the way Xcode lists it, while a
/// cycle along one path (only a corrupt image has one) is still cut, and a
/// depth cap backs that up.
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

    func trees(for query: RuntimeTypeRelationshipsQuery) async -> [RuntimeRelationshipTree] {
        let candidates = await candidateTypes(matching: query)
        var trees: [RuntimeRelationshipTree] = []
        trees.reserveCapacity(candidates.count)
        for candidate in candidates {
            var visited: Set<String> = [visitedKey(for: candidate)]
            let nodes: [RuntimeRelationshipNode]
            switch query.relationship {
            case .ancestors:
                nodes = await ancestorNodes(of: candidate, visited: visited, depth: 0)
            case .descendants:
                nodes = await descendantNodes(of: candidate, visited: visited, depth: 0)
            case .conformers:
                nodes = await conformerNodes(of: candidate)
            }
            trees.append(RuntimeRelationshipTree(root: candidate, nodes: nodes))
        }
        return trees
    }

    /// The types whose name matches the query, exact matches first, then by
    /// name. A Swift type matches on its qualified display name and on its
    /// last component, so `View` finds `SwiftUI.View`.
    private func candidateTypes(matching query: RuntimeTypeRelationshipsQuery) async -> [RuntimeObject] {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let options: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]

        var exactMatches: OrderedSet<RuntimeObject> = []
        var partialMatches: OrderedSet<RuntimeObject> = []
        func consider(_ object: RuntimeObject) {
            guard Self.isRelationshipCandidate(object) else { return }
            let names = [object.displayName, object.displayName.components(separatedBy: ".").last ?? object.displayName]
            if names.contains(where: { $0.compare(text, options: options) == .orderedSame }) {
                exactMatches.append(object)
            } else if names.contains(where: { $0.range(of: text, options: options) != nil }) {
                partialMatches.append(object)
            }
        }
        func considerTree(_ object: RuntimeObject) {
            consider(object)
            for child in object.children {
                considerTree(child)
            }
        }

        for imagePath in await objcSectionFactory.cachedImagePaths.sorted() {
            guard let section = await objcSectionFactory.existingSection(for: imagePath),
                  let objects = try? await section.allObjects()
            else { continue }
            objects.forEach(considerTree)
        }
        for imagePath in await swiftSectionFactory.cachedImagePaths.sorted() {
            guard let section = await swiftSectionFactory.existingSection(for: imagePath),
                  let objects = try? await section.allObjects()
            else { continue }
            objects.forEach(considerTree)
        }

        let sortedPartialMatches = partialMatches.sorted { left, right in
            left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
        return Array((Array(exactMatches) + sortedPartialMatches).prefix(max(0, query.candidateLimit)))
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

    private func ancestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        switch object.kind {
        case .objc(.type(.class)):
            return await objcClassAncestorNodes(named: object.name, visited: visited, depth: depth)
        case .objc(.type(.protocol)):
            return await objcProtocolAncestorNodes(named: object.name, visited: visited, depth: depth)
        case .swift(.type(.protocol)):
            let qualifiedName = swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
            return await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, visited: visited, depth: depth)
        case .swift(.type):
            return await swiftTypeAncestorNodes(of: object, visited: visited, depth: depth)
        default:
            return []
        }
    }

    /// An Objective-C class's ancestors: the protocols it adopts, then its
    /// superclass carrying the same for itself, recursively — the shape
    /// Xcode nests them in.
    private func objcClassAncestorNodes(named className: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard let (group, _) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className),
              let classInfo = group.info.first
        else { return [] }
        var nodes = await objcProtocolNodes(named: classInfo.protocols.map(\.name), visited: visited, depth: depth + 1)
        if let superclassName = classInfo.superClassName, !superclassName.isEmpty {
            let key = "objc:" + superclassName
            if !visited.contains(key) {
                var visited = visited
                visited.insert(key)
                let superclass = await materializeObjCClass(named: superclassName)
                let children = await objcClassAncestorNodes(named: superclassName, visited: visited, depth: depth + 1)
                nodes.append(RuntimeRelationshipNode(name: superclass?.displayName ?? superclassName, object: superclass, children: children))
            }
        }
        return nodes
    }

    private func objcProtocolAncestorNodes(named protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        await objcProtocolNodes(named: objcSectionFactory.indexer.refinedProtocolNames(of: protocolName), visited: visited, depth: depth + 1)
    }

    /// Nodes for Objective-C protocols by name, each carrying the protocols
    /// it adopts underneath.
    private func objcProtocolNodes(named protocolNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        var nodes: [RuntimeRelationshipNode] = []
        for protocolName in protocolNames {
            let key = "objcProtocol:" + protocolName
            guard !visited.contains(key) else { continue }
            var visited = visited
            visited.insert(key)
            let object = await materializeObjCProtocol(named: protocolName)
            let children = await objcProtocolAncestorNodes(named: protocolName, visited: visited, depth: depth)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? protocolName, object: object, children: children))
        }
        return nodes
    }

    /// A Swift struct's, enum's, actor's or class's ancestors: the protocols
    /// it conforms to, then — for a class — its superclass with the same
    /// underneath. A superclass no Swift image defines is looked up as an
    /// Objective-C class by its printed name before it is given up on.
    private func swiftTypeAncestorNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        let indexer = swiftSectionFactory.indexer
        var nodes = await swiftProtocolNodes(
            qualifiedNames: indexer.conformingProtocolNames(forMangledTypeName: object.name).map(\.name),
            visited: visited,
            depth: depth + 1
        )
        guard case .swift(.type(.class)) = object.kind,
              let superclassMangledName = indexer.superclassMangledName(forMangledTypeName: object.name)
        else { return nodes }

        if let superclass = await materializeSwiftType(mangledName: superclassMangledName) {
            guard !visited.contains(visitedKey(for: superclass)) else { return nodes }
            var visited = visited
            visited.insert(visitedKey(for: superclass))
            let children = await swiftTypeAncestorNodes(of: superclass, visited: visited, depth: depth + 1)
            nodes.append(RuntimeRelationshipNode(object: superclass, children: children))
            return nodes
        }

        let displayName = indexer.superclassDisplayName(forMangledTypeName: object.name) ?? superclassMangledName
        let simpleName = displayName.components(separatedBy: ".").last ?? displayName
        if let objcSuperclass = await materializeObjCClass(named: simpleName) {
            guard !visited.contains(visitedKey(for: objcSuperclass)) else { return nodes }
            var visited = visited
            visited.insert(visitedKey(for: objcSuperclass))
            let children = await ancestorNodes(of: objcSuperclass, visited: visited, depth: depth + 1)
            nodes.append(RuntimeRelationshipNode(object: objcSuperclass, children: children))
        } else if !visited.contains("unresolved:" + displayName) {
            nodes.append(RuntimeRelationshipNode(name: displayName, object: nil, children: []))
        }
        return nodes
    }

    private func swiftProtocolAncestorNodes(qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        var nodes: [RuntimeRelationshipNode] = []
        for refined in swiftSectionFactory.indexer.refinedProtocols(ofQualifiedName: qualifiedName) {
            if refined.isObjC {
                nodes += await objcProtocolNodes(named: [refined.qualifiedName], visited: visited, depth: depth + 1)
            } else {
                nodes += await swiftProtocolNodes(qualifiedNames: [refined.qualifiedName], visited: visited, depth: depth + 1)
            }
        }
        return nodes
    }

    /// Nodes for Swift protocols by qualified name, each carrying the
    /// protocols it refines underneath.
    private func swiftProtocolNodes(qualifiedNames: [String], visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        var nodes: [RuntimeRelationshipNode] = []
        for qualifiedName in qualifiedNames {
            let key = "swiftProtocol:" + qualifiedName
            guard !visited.contains(key) else { continue }
            var visited = visited
            visited.insert(key)
            let object = await materializeSwiftProtocol(qualifiedName: qualifiedName)
            let children = await swiftProtocolAncestorNodes(qualifiedName: qualifiedName, visited: visited, depth: depth)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? qualifiedName, object: object, children: children))
        }
        return nodes
    }

    // MARK: - Descendants

    private func descendantNodes(of object: RuntimeObject, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        switch object.kind {
        case .objc(.type(.class)), .swift(.type(.class)):
            var nodes: [RuntimeRelationshipNode] = []
            for subclass in await relationshipsResolver.relationships(for: object).subclasses {
                guard !visited.contains(visitedKey(for: subclass)) else { continue }
                var visited = visited
                visited.insert(visitedKey(for: subclass))
                let children = await descendantNodes(of: subclass, visited: visited, depth: depth + 1)
                nodes.append(RuntimeRelationshipNode(object: subclass, children: children))
            }
            return nodes
        case .objc(.type(.protocol)):
            return await refiningProtocolNodes(ofObjCProtocolNamed: object.name, visited: visited, depth: depth)
        case .swift(.type(.protocol)):
            let qualifiedName = swiftSectionFactory.indexer.protocolName(forMangledName: object.name)?.name ?? object.displayName
            return await refiningProtocolNodes(ofSwiftProtocolNamed: qualifiedName, visited: visited, depth: depth)
        default:
            return []
        }
    }

    /// The protocols refining an Objective-C protocol: Objective-C ones from
    /// the ObjC tables, and Swift ones — a Swift protocol may refine an
    /// Objective-C protocol — from the Swift tables, which key them by the
    /// same runtime name.
    private func refiningProtocolNodes(ofObjCProtocolNamed protocolName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        var nodes: [RuntimeRelationshipNode] = []
        for reference in objcSectionFactory.indexer.refiningProtocols(of: protocolName) {
            let key = "objcProtocol:" + reference.protocolName
            guard !visited.contains(key) else { continue }
            var visited = visited
            visited.insert(key)
            let object = await objcSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forProtocolName: reference.protocolName)
            let children = await refiningProtocolNodes(ofObjCProtocolNamed: reference.protocolName, visited: visited, depth: depth + 1)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.protocolName, object: object, children: children))
        }
        nodes += await swiftRefiningProtocolNodes(of: protocolName, visited: visited, depth: depth)
        return nodes
    }

    private func refiningProtocolNodes(ofSwiftProtocolNamed qualifiedName: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        await swiftRefiningProtocolNodes(of: qualifiedName, visited: visited, depth: depth)
    }

    private func swiftRefiningProtocolNodes(of name: String, visited: Set<String>, depth: Int) async -> [RuntimeRelationshipNode] {
        guard depth < Self.maximumDepth else { return [] }
        var nodes: [RuntimeRelationshipNode] = []
        for reference in swiftSectionFactory.indexer.refiningProtocols(ofQualifiedName: name) {
            let key = "swiftProtocol:" + reference.qualifiedName
            guard !visited.contains(key) else { continue }
            var visited = visited
            visited.insert(key)
            let object = await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
            let children = await swiftRefiningProtocolNodes(of: reference.qualifiedName, visited: visited, depth: depth + 1)
            nodes.append(RuntimeRelationshipNode(name: object?.displayName ?? reference.qualifiedName, object: object, children: children))
        }
        return nodes
    }

    // MARK: - Conformers

    private func conformerNodes(of object: RuntimeObject) async -> [RuntimeRelationshipNode] {
        await relationshipsResolver.relationships(for: object).conformingTypes.map { RuntimeRelationshipNode(object: $0) }
    }

    // MARK: - Materialization

    /// The `RuntimeObject` for an Objective-C class from whichever indexed
    /// image declares it — as its Swift face when the class is a Swift class,
    /// the way the sidebar and the Inspector list it.
    private func materializeObjCClass(named className: String) async -> RuntimeObject? {
        guard let (group, imagePath) = objcSectionFactory.indexer.classGroupAcrossImages(forName: className) else { return nil }
        if group.objcClass.isSwiftStable,
           let swiftSection = await swiftSectionFactory.existingSection(for: imagePath),
           let swiftObject = await swiftSection.makeRuntimeObject(forObjCRuntimeClassName: className) {
            return swiftObject
        }
        return await objcSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forClassName: className)
    }

    private func materializeObjCProtocol(named protocolName: String) async -> RuntimeObject? {
        guard let (_, imagePath) = objcSectionFactory.indexer.protocolGroupAcrossImages(forName: protocolName) else { return nil }
        return await objcSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forProtocolName: protocolName)
    }

    private func materializeSwiftType(mangledName: String) async -> RuntimeObject? {
        guard let (_, imagePath) = swiftSectionFactory.indexer.typeDefinition(forMangledName: mangledName) else { return nil }
        return await swiftSectionFactory.existingSection(for: imagePath)?.makeRuntimeObject(forMangledTypeName: mangledName)
    }

    private func materializeSwiftProtocol(qualifiedName: String) async -> RuntimeObject? {
        guard let reference = swiftSectionFactory.indexer.protocolReference(forQualifiedName: qualifiedName) else { return nil }
        return await swiftSectionFactory.existingSection(for: reference.imagePath)?.makeRuntimeObject(forMangledProtocolName: reference.mangledName)
    }

    private func visitedKey(for object: RuntimeObject) -> String {
        "\(object.kind)|\(object.name)"
    }
}
