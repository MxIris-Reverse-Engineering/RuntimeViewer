import Foundation

public final class RuntimeImageNode: Codable {
    private enum CodingKeys: CodingKey {
        case name
        case children
        case absolutePath
    }

    public let name: String

    public private(set) weak var parent: RuntimeImageNode?

    public private(set) var children: [RuntimeImageNode] = []

    /// Absolute path from the tree root.
    ///
    /// This is serialized explicitly rather than left to the lazy derivation below. A
    /// `RuntimeImageBookmark` persists a single node detached from its ancestors, so on decode
    /// `parent` is nil and the derivation collapses to `"/" + name` — turning `path` into `"/"`
    /// and breaking image loading. Never remove `.absolutePath` from `CodingKeys`.
    public private(set) lazy var absolutePath: String = {
        guard let parent else { return "/" + name }
        let directory = parent.absolutePath
        return directory + "/" + name
    }()

    public init(_ name: String, parent: RuntimeImageNode? = nil) {
        self.parent = parent
        self.name = name
    }

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

    public static func rootNode(for imagePaths: [String], name: String = "") -> RuntimeImageNode {
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
        try container.encode(absolutePath, forKey: .absolutePath)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.children = try container.decode([RuntimeImageNode].self, forKey: .children)

        // Only assign when the payload actually carries a path. Leaving the lazy var
        // unmaterialized on the nil branch lets descendants of a node written without
        // `.absolutePath` still derive from the parent restored just below, instead of
        // freezing at `"/" + name`.
        if let decodedAbsolutePath = try container.decodeIfPresent(String.self, forKey: .absolutePath) {
            self.absolutePath = decodedAbsolutePath
        }

        for child in children {
            child.parent = self
        }
    }
}

extension RuntimeImageNode: Hashable {
    public static func == (lhs: RuntimeImageNode, rhs: RuntimeImageNode) -> Bool {
        lhs.name == rhs.name && lhs.children == rhs.children && lhs.absolutePath == rhs.absolutePath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(children)
        hasher.combine(absolutePath)
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
