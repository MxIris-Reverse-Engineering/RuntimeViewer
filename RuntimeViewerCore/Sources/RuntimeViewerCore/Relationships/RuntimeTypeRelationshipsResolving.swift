import Foundation

/// The Find navigator's relationship trees and the Inspector's hierarchies.
protocol RuntimeTypeRelationshipsResolving: Actor {
    func trees(for query: RuntimeTypeRelationshipsQuery) async throws -> [RuntimeRelationshipTree]

    func refinedProtocolTree(of object: RuntimeObject) async throws -> [RuntimeRelationshipNode]

    func superclassChain(of object: RuntimeObject) async throws -> [RuntimeRelationshipNode]
}
