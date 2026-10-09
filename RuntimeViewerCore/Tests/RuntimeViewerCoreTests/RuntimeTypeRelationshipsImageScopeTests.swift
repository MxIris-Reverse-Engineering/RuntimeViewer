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

    /// The rule on its own, with no image: the copy of the image that named
    /// the protocol, then the first by path among the query's images, then
    /// the first by path.
    @Test("the copy of an Objective-C protocol a node stands for")
    func protocolCopyChoice() {
        let carrierImagePaths = ["/images/B", "/images/A", "/images/C"]
        // The image that named the protocol, when it carries one.
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: "/images/C", imagePaths: nil) == "/images/C")
        // Otherwise the first carrier by path, whatever order they came in.
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: "/images/D", imagePaths: nil) == "/images/A")
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: nil, imagePaths: nil) == "/images/A")
        // A limited query never leaves its images for the referencing one.
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: "/images/C", imagePaths: ["/images/B"]) == "/images/B")
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: "/images/C", imagePaths: ["/images/C", "/images/A"]) == "/images/C")
        // No carrier inside the images: the first carrier by path, cut later.
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: carrierImagePaths, referencedFrom: nil, imagePaths: ["/images/X"]) == "/images/A")
        // Nothing carries it.
        #expect(RuntimeTypeRelationshipsResolver.preferredCarrierImagePath(among: [], referencedFrom: "/images/C", imagePaths: nil) == nil)
    }
}
