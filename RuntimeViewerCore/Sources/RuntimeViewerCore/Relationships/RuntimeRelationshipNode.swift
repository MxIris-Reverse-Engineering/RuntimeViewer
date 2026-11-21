import Foundation

/// One node of a relationship tree, or, without children, one level of a
/// superclass chain (`RuntimeEngine.superclassChain(for:)`).
///
/// `object` is `nil` for a type no indexed image defines — a superclass in a
/// framework that was never indexed, a protocol only known by name from a
/// requirement signature. The node still shows up under `name`; it just
/// cannot be navigated to.
public struct RuntimeRelationshipNode: Hashable, Codable, Sendable {
    /// Whether the type a node names is a class or a protocol.
    public enum TypeKind: String, Hashable, Codable, Sendable {
        case `class`
        case `protocol`

        /// The kind `object` is; `nil` for a type that is neither, such as a
        /// Swift struct conforming to a protocol.
        public init?(of object: RuntimeObject) {
            switch object.kind {
            case .objc(.type(.class)), .swift(.type(.class)), .cPlusPlus(.class):
                self = .class
            case .objc(.type(.protocol)), .swift(.type(.protocol)):
                self = .protocol
            default:
                return nil
            }
        }
    }

    public let name: String
    public let object: RuntimeObject?
    public let children: [RuntimeRelationshipNode]

    /// Whether `name` names a class or a protocol. One name can name both —
    /// `NSObject` does — so an engine that looks an unresolved node up by
    /// name, as one borrowing shared cache images asks the images' owners to,
    /// must not take the one for the other. `nil` for a node of neither kind,
    /// and for one a peer of an earlier release built, which did not say.
    public let typeKind: TypeKind?

    public init(name: String, typeKind: TypeKind?, object: RuntimeObject?, children: [RuntimeRelationshipNode]) {
        self.name = name
        self.typeKind = typeKind
        self.object = object
        self.children = children
    }

    public init(object: RuntimeObject, children: [RuntimeRelationshipNode] = []) {
        self.init(name: object.displayName, typeKind: TypeKind(of: object), object: object, children: children)
    }

    public var isResolved: Bool { object != nil }

    /// This node with `children` underneath instead of its own.
    public func replacingChildren(_ children: [RuntimeRelationshipNode]) -> RuntimeRelationshipNode {
        RuntimeRelationshipNode(name: name, typeKind: typeKind, object: object, children: children)
    }
}
