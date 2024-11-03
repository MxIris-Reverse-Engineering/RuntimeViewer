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

    private enum CodingKeys: CodingKey {
        case name
        case children
    }

    public init(_ name: String, parent: RuntimeNamedNode? = nil) {
        self.parent = parent
        self.name = name
    }

    public lazy var absolutePath: String = {
        guard let parent else { return "/" + name }
        let directory = parent.absolutePath
        return directory + "/" + name
    }()
    
    public var path: String { absolutePath.removeFirstPathComponent() }

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(children, forKey: .children)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.children = try container.decode([RuntimeNamedNode].self, forKey: .children)

        for child in children {
            child.parent = self
        }
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

extension String {
    /// 移除路径中的第一个组件，保持原始路径的绝对/相对特性
    /// 例如:
    /// - "/path/to/file" -> "/to/file"
    /// - "path/to/file" -> "to/file"
    /// - "/path" -> "/"
    /// - "path" -> ""
    /// - "/" -> "/"
    /// - "" -> ""
    func removeFirstPathComponent() -> String {
        let isAbsolute = self.hasPrefix("/")
        var components = self.split(separator: "/", omittingEmptySubsequences: true)
        
        guard !components.isEmpty else {
            return isAbsolute ? "/" : ""
        }
        
        components.removeFirst()
        
        if components.isEmpty {
            return isAbsolute ? "/" : ""
        }
        
        return isAbsolute ? "/" + components.joined(separator: "/") : components.joined(separator: "/")
    }
}
