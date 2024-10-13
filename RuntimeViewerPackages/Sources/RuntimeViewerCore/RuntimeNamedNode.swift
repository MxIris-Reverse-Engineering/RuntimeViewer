//
//  NamedNode.swift
//  HeaderViewer
//
//  Created by Leptos on 2/18/24.
//

import Foundation

public final class RuntimeNamedNode: Codable {
    public let name: String
    
    public weak var parent: RuntimeNamedNode?

    public var children: [RuntimeNamedNode] = []

    public init(_ name: String, parent: RuntimeNamedNode? = nil) {
        self.parent = parent
        self.name = name
    }

    public lazy var path: String = {
        guard let parent else { return "" }
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
    
    public class func rootNode(for imagePaths: [String], name: String = "") -> RuntimeNamedNode {
        let root = RuntimeNamedNode(name)
        for path in imagePaths {
            var current = root
            for pathComponent in path.split(separator: "/") {
                switch pathComponent {
                case ".":
                    break // current
                case "..":
                    if let parent = current.parent {
                        current = parent
                    }
                default:
                    current = current.child(named: String(pathComponent))
                }
            }
        }
        return root
    }
}

extension RuntimeNamedNode: Hashable {
    public static func == (lhs: RuntimeNamedNode, rhs: RuntimeNamedNode) -> Bool {
        lhs.name == rhs.name && lhs.children == rhs.children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(children)
    }
}
