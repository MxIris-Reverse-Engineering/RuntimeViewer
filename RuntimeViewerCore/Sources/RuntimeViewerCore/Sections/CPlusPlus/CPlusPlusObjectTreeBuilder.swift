import Foundation

/// Makes the runtime objects of an image's C++ section out of the image's
/// scope tree and the classes its run-time type information shows.
///
/// A scope of kind `type` and a class with run-time type information are
/// `.cPlusPlus(.class)` objects, merged by qualified name; a scope of kind
/// `namespace` or `undetermined` is a `.cPlusPlus(.namespace)` object. A
/// function scope — what a local entity or a lambda sits in — is no object,
/// and nothing below it is either. A class only run-time type information
/// shows is put under the scopes its name passes through, the missing ones
/// made up: a class when the scope above is one, a namespace otherwise. A
/// namespace with no symbol of its own and nothing below it is left out, and
/// symbols at global scope get an object of their own, ``globalNamespaceName``.
///
/// Works on plain values rather than MachOKitExtensions' stores, so that its
/// rules are tested on made-up trees; `RuntimeCPlusPlusSection` reads the
/// stores into these values.
struct CPlusPlusObjectTreeBuilder {
    /// The name of the object that stands for the global namespace, when
    /// symbols sit directly in it: what no qualified name of a scope is.
    static let globalNamespaceName = "::"

    /// What the reader is shown for ``globalNamespaceName``.
    static let globalNamespaceDisplayName = "Global Namespace"

    /// A scope of the image's tree, as far as the builder needs it.
    struct Scope: Sendable {
        enum Kind: Sendable {
            case namespace
            case type
            case function
            case undetermined
        }

        /// The components, outermost first, each as C++ prints it.
        var path: [String]
        var kind: Kind
        /// Whether a symbol sits directly in the scope. Asked only of a
        /// namespace that keeps nothing below it, because answering means
        /// reading the scope's members.
        var hasMembers: @Sendable () -> Bool
        var children: [Scope]
    }

    let imagePath: String

    /// The top-level objects: `globalScope`'s children made into objects,
    /// `classPaths` put among them, and the global namespace's object when
    /// `globalScope` has members. `globalScope` is the tree's root; its own
    /// path is empty. `classPaths` are the scope paths of the classes with
    /// run-time type information.
    func objects(globalScope: Scope, classPaths: [[String]]) -> [RuntimeObject] {
        let root = Node(component: "", kind: .namespace, hasMembers: globalScope.hasMembers)
        for child in globalScope.children {
            root.insert(child)
        }
        for classPath in classPaths where !classPath.isEmpty {
            root.insertClass(at: classPath[...])
        }
        var objects = root.children.values.compactMap { $0.object(parentPath: [], imagePath: imagePath) }
        if root.hasMembers() {
            objects.append(RuntimeObject(
                name: Self.globalNamespaceName,
                displayName: Self.globalNamespaceDisplayName,
                kind: .cPlusPlus(.namespace),
                imagePath: imagePath,
                children: []
            ))
        }
        return objects.sorted()
    }

    /// Whether `component` names a function: a `(` outside any template
    /// argument list, other than the one an anonymous namespace is spelled
    /// with. A class only run-time type information shows can sit in a
    /// function the scope tree does not have.
    static func isFunctionComponent(_ component: String) -> Bool {
        guard component != "(anonymous namespace)" else { return false }
        var templateDepth = 0
        for character in component {
            switch character {
            case "<":
                templateDepth += 1
            case ">":
                templateDepth = max(0, templateDepth - 1)
            case "(" where templateDepth == 0:
                return true
            default:
                break
            }
        }
        return false
    }
}

extension CPlusPlusObjectTreeBuilder {
    /// A scope while the tree is being put together.
    private final class Node {
        enum Kind {
            case namespace
            case `class`
            /// A function scope: dropped with everything below it.
            case function
        }

        let component: String
        var kind: Kind
        var hasMembers: @Sendable () -> Bool
        var children: [String: Node] = [:]

        init(component: String, kind: Kind, hasMembers: @escaping @Sendable () -> Bool) {
            self.component = component
            self.kind = kind
            self.hasMembers = hasMembers
        }

        func insert(_ scope: Scope) {
            guard let component = scope.path.last else { return }
            let kind: Kind = switch scope.kind {
            case .type: .class
            case .namespace, .undetermined: .namespace
            case .function: .function
            }
            let node = Node(component: component, kind: kind, hasMembers: scope.hasMembers)
            children[component] = node
            guard kind != .function else { return }
            for child in scope.children {
                node.insert(child)
            }
        }

        /// Puts a class with run-time type information at `path`, below this
        /// node. Run-time type information is stronger evidence than the
        /// scope tree's, so an existing namespace becomes a class.
        func insertClass(at path: ArraySlice<String>) {
            guard let component = path.first else { return }
            let isLast = path.count == 1
            if let node = children[component] {
                if node.kind == .function { return }
                if isLast {
                    node.kind = .class
                } else {
                    node.insertClass(at: path.dropFirst())
                }
                return
            }
            if !isLast && CPlusPlusObjectTreeBuilder.isFunctionComponent(component) { return }
            let kind: Kind = isLast || self.kind == .class ? .class : .namespace
            let node = Node(component: component, kind: kind, hasMembers: { false })
            children[component] = node
            if !isLast {
                node.insertClass(at: path.dropFirst())
            }
        }

        /// The node as an object, `nil` for a function scope and for a
        /// namespace with nothing in it.
        func object(parentPath: [String], imagePath: String) -> RuntimeObject? {
            guard kind != .function else { return nil }
            let path = parentPath + [component]
            let childObjects = children.values.compactMap { $0.object(parentPath: path, imagePath: imagePath) }.sorted()
            if kind == .namespace, childObjects.isEmpty, !hasMembers() {
                return nil
            }
            return RuntimeObject(
                name: path.joined(separator: "::"),
                displayName: component,
                kind: kind == .class ? .cPlusPlus(.class) : .cPlusPlus(.namespace),
                imagePath: imagePath,
                children: childObjects
            )
        }
    }
}
