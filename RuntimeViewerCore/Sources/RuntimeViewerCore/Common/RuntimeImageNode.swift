import Foundation

public final class RuntimeImageNode: Codable {
    public let name: String

    public weak var parent: RuntimeImageNode?

    public var children: [RuntimeImageNode] = []

    private enum CodingKeys: CodingKey {
        case name
        case children
    }

    public init(_ name: String, parent: RuntimeImageNode? = nil) {
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

    public func child(named name: String) -> RuntimeImageNode {
        if let existing = children.first(where: { $0.name == name }) {
            return existing
        }
        let child = RuntimeImageNode(name, parent: self)
        children.append(child)
        return child
    }

    public class func rootNode(for imagePaths: [String], name: String = "") -> RuntimeImageNode {
        let root = RuntimeImageNode(name)
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
        self.children = try container.decode([RuntimeImageNode].self, forKey: .children)

        for child in children {
            child.parent = self
        }
    }
}

extension RuntimeImageNode: Hashable {
    public static func == (lhs: RuntimeImageNode, rhs: RuntimeImageNode) -> Bool {
        lhs.name == rhs.name && lhs.children == rhs.children
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(children)
    }
}

extension String {
    func removeFirstPathComponent() -> String {
        let isAbsolute = hasPrefix("/")
        var components = split(separator: "/", omittingEmptySubsequences: true)

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
