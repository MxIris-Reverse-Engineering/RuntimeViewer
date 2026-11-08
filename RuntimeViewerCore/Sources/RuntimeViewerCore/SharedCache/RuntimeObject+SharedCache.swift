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
}
