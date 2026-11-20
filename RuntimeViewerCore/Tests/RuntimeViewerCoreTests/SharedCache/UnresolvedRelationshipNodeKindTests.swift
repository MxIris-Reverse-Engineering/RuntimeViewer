import Foundation
import Testing
@testable import RuntimeViewerCore

/// How the nodes a borrowing engine could not resolve are matched with the
/// trees its owners answer: by name and by kind.
@Suite("Unresolved relationship nodes resolve by name and kind")
struct UnresolvedRelationshipNodeKindTests {
    private static func object(_ kind: RuntimeObjectKind, in imagePath: String) -> RuntimeObject {
        RuntimeObject(name: "NSObject", displayName: "NSObject", kind: kind, imagePath: imagePath, children: [])
    }

    private static let classTree = RuntimeRelationshipTree(
        root: object(.objc(.type(.class)), in: "/usr/lib/libobjc.A.dylib"),
        nodes: []
    )

    private static let protocolTree = RuntimeRelationshipTree(
        root: object(.objc(.type(.protocol)), in: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"),
        nodes: []
    )

    private static let resolvedTrees: [RuntimeRelationshipNode.UnresolvedType: RuntimeRelationshipTree] = [
        .init(name: "NSObject", kind: .class): classTree,
        .init(name: "NSObject", kind: .protocol): protocolTree,
    ]

    @Test("a class node takes the class's tree and a protocol node the protocol's")
    func eachNodeTakesTheTreeOfItsKind() {
        let nodes = [
            RuntimeRelationshipNode(name: "NSObject", typeKind: .class, object: nil, children: [
                RuntimeRelationshipNode(name: "NSObject", typeKind: .protocol, object: nil, children: []),
            ]),
        ]

        let resolved = nodes.resolving(Self.resolvedTrees)

        #expect(resolved.first?.object == Self.classTree.root)
        #expect(resolved.first?.typeKind == .class)
        // The class's tree replaces the node whole, its children with it.
        #expect(resolved.first?.children.isEmpty == true)
        #expect(nodes.unresolvedTypes().elements == [
            .init(name: "NSObject", kind: .class),
            .init(name: "NSObject", kind: .protocol),
        ])
        #expect(nodes[0].children.resolving(Self.resolvedTrees).first?.object == Self.protocolTree.root)
    }

    @Test("a node that does not say its kind takes the kind its caller assumes")
    func nodeWithoutKindTakesTheAssumedKind() {
        let nodes = [RuntimeRelationshipNode(name: "NSObject", typeKind: nil, object: nil, children: [])]

        #expect(nodes.resolving(Self.resolvedTrees, assumingKind: .class).first?.object == Self.classTree.root)
        #expect(nodes.resolving(Self.resolvedTrees, assumingKind: .protocol).first?.object == Self.protocolTree.root)
        #expect(nodes.resolving(Self.resolvedTrees).first?.object == nil)
    }

    @Test("an object is the type an unresolved node stands for only when the kinds agree")
    func objectMatchesByNameAndKind() {
        #expect(Self.classTree.root.isType(.init(name: "NSObject", kind: .class)))
        #expect(!Self.classTree.root.isType(.init(name: "NSObject", kind: .protocol)))
        #expect(Self.protocolTree.root.isType(.init(name: "NSObject", kind: nil)))
        #expect(!Self.protocolTree.root.isType(.init(name: "NSString", kind: .protocol)))
    }

    @Test("a node from a peer of an earlier release, without a kind, still decodes")
    func nodeWithoutKindDecodes() throws {
        let encoded = Data(#"{"name":"NSObject","children":[]}"#.utf8)

        let node = try JSONDecoder().decode(RuntimeRelationshipNode.self, from: encoded)

        #expect(node.name == "NSObject")
        #expect(node.typeKind == nil)
        #expect(node.object == nil)
    }
}
