import Testing
@testable import RuntimeViewerCore

/// A relationship tree kept to some images' types, on hand-built nodes: which
/// nodes stay, and which stay only because of what they lead to.
@Suite("Relationship trees limited to images")
struct RuntimeTypeRelationshipsImageScopeTests {
    private static let insideImagePath = "/images/Inside"
    private static let outsideImagePath = "/images/Outside"

    /// A node for a class of `imagePath`, or for a type no indexed image
    /// defines when `imagePath` is `nil`.
    private static func node(_ name: String, in imagePath: String?, children: [RuntimeRelationshipNode] = []) -> RuntimeRelationshipNode {
        let object = imagePath.map { RuntimeObject(name: name, displayName: name, kind: .objc(.type(.class)), imagePath: $0, children: []) }
        return RuntimeRelationshipNode(name: name, object: object, children: children)
    }

    @Test("a node outside the images stays only for the types inside them it leads to")
    func keepsInsideTypesAndThePathsToThem() {
        let nodes = [
            Self.node("PathToInside", in: Self.outsideImagePath, children: [Self.node("Inside", in: Self.insideImagePath)]),
            Self.node("OutsideOnly", in: Self.outsideImagePath, children: [Self.node("AlsoOutside", in: Self.outsideImagePath)]),
            Self.node("InsideWithOutsideChild", in: Self.insideImagePath, children: [Self.node("OutsideChild", in: Self.outsideImagePath)]),
            Self.node("UnresolvedToInside", in: nil, children: [Self.node("InsideBelowUnresolved", in: Self.insideImagePath)]),
            Self.node("UnresolvedOnly", in: nil),
        ]

        let keptNodes = RuntimeTypeRelationshipsResolver.nodes(nodes, leadingInto: [Self.insideImagePath])

        #expect(keptNodes == [
            Self.node("PathToInside", in: Self.outsideImagePath, children: [Self.node("Inside", in: Self.insideImagePath)]),
            Self.node("InsideWithOutsideChild", in: Self.insideImagePath),
            Self.node("UnresolvedToInside", in: nil, children: [Self.node("InsideBelowUnresolved", in: Self.insideImagePath)]),
        ])
    }
}
