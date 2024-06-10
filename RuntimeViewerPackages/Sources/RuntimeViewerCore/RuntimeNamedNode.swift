//
//  NamedNode.swift
//  HeaderViewer
//
//  Created by Leptos on 2/18/24.
//

import Foundation

public final class RuntimeNamedNode {
    public let name: String
    public weak var parent: RuntimeNamedNode?

    public var children: [RuntimeNamedNode] = []

    public init(_ name: String, parent: RuntimeNamedNode? = nil) {
        self.parent = parent
        self.name = name
    }

    public lazy var path: String = {
        guard let parent else { return name }
        let directory = parent.path
        return directory + "/" + name
    }()

    public var isLeaf: Bool { children.isEmpty }

    public func child(named name: String) -> RuntimeNamedNode {
        if let existing = children.first(where: { $0.name == name }) {
            return existing
        }
        let child = RuntimeNamedNode(name, parent: self)
        children.append(child)
        return child
    }
}

extension RuntimeNamedNode: Hashable {
    public static func == (lhs: RuntimeNamedNode, rhs: RuntimeNamedNode) -> Bool {
        lhs.name == rhs.name && lhs.parent === rhs.parent
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(parent)
    }
}
