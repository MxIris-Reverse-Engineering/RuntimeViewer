import Foundation

extension RuntimeObject {
    /// The object without its nested types and specializations, which a type
    /// handed to another engine to look its relatives up by does not need.
    var strippedOfChildren: RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName,
            kind: kind,
            imagePath: imagePath,
            children: [],
            properties: properties,
            privateDeclarations: privateDeclarations
        )
    }

    /// Whether `name` — the name a node for a type no image defines carries —
    /// names this object: its display name, its runtime name, or its own name
    /// without the module and enclosing types.
    func isNamed(_ name: String) -> Bool {
        displayName == name || self.name == name || RuntimeInterfaceTextMatcher.ownTypeName(of: displayName) == name
    }

    /// Whether this object is the type `unresolvedType` stands for: named by
    /// its name, and of its kind when it has one — the `NSObject` protocol is
    /// not the `NSObject` class.
    func isType(_ unresolvedType: RuntimeRelationshipNode.UnresolvedType) -> Bool {
        guard isNamed(unresolvedType.name) else { return false }
        guard let kind = unresolvedType.kind else { return true }
        return RuntimeRelationshipNode.TypeKind(of: self) == kind
    }
}
