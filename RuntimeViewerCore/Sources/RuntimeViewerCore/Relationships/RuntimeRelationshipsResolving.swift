import Foundation

/// The Inspector's Relationships rows.
protocol RuntimeRelationshipsResolving: Actor {
    func relationships(for object: RuntimeObject) async -> RuntimeRelationships
}
