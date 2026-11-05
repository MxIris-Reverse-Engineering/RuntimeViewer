import Foundation

/// One node of a relationship tree, or, without children, one level of a
/// superclass chain (`RuntimeEngine.superclassChain(for:)`).
///
/// `object` is `nil` for a type no indexed image defines — a superclass in a
/// framework that was never indexed, a protocol only known by name from a
/// requirement signature. The node still shows up under `name`; it just
/// cannot be navigated to.
public struct RuntimeRelationshipNode: Hashable, Codable, Sendable {
    public let name: String
    public let object: RuntimeObject?
    public let children: [RuntimeRelationshipNode]

    public init(name: String, object: RuntimeObject?, children: [RuntimeRelationshipNode]) {
        self.name = name
        self.object = object
        self.children = children
    }

    public init(object: RuntimeObject, children: [RuntimeRelationshipNode] = []) {
        self.init(name: object.displayName, object: object, children: children)
    }

    public var isResolved: Bool { object != nil }
}
