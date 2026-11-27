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
/// The specializations of one class template in one scope are gathered under
/// a `.cPlusPlus(.classTemplate)` object named after the template, even when
/// there is only one: `std::__1::vector` holds `vector<int, …>` and
/// `vector<char, …>`, which keep their names and what is below them. A
/// specialization is a scope whose base name — its component without template
/// arguments, which MachOKitExtensions reads off the demangled name — differs
/// from its component, whatever its kind: a namespace takes no template
/// arguments, but the symbols may leave a specialization `undetermined`. A
/// scope made up for a class only run-time type information shows has no base
/// name and is never one, and no node is made for a template whose name a
/// sibling already has, so that no two objects share a name. Template nodes
/// sort after the classes and before the namespaces, as their kind does.
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
        /// The last component without template arguments, as
        /// `CPlusPlusScope.baseName` gives it: the same for every
        /// specialization of one class template.
        var baseName: String
        var kind: Kind
        /// Whether a symbol sits directly in the scope. Asked only of a
        /// namespace that keeps nothing below it, because answering means
        /// reading the scope's members.
        var hasMembers: @Sendable () -> Bool
        var children: [Scope]
    }

    /// A class with run-time type information.
    struct ClassName: Sendable {
        /// The components of its qualified name, outermost first.
        var path: [String]
        /// The last component without template arguments, as
        /// `CPlusPlusClass.baseName` gives it.
        var baseName: String
    }

    let imagePath: String

    /// The top-level objects: `globalScope`'s children made into objects,
    /// `classes` put among them, and the global namespace's object when
    /// `globalScope` has members. `globalScope` is the tree's root; its own
    /// path is empty.
    func objects(globalScope: Scope, classes: [ClassName]) -> [RuntimeObject] {
        let root = Node(component: "", baseName: nil, kind: .namespace, hasMembers: globalScope.hasMembers)
        for child in globalScope.children {
            root.insert(child)
        }
        for className in classes where !className.path.isEmpty {
            root.insertClass(at: className.path[...], baseName: className.baseName)
        }
        var objects = root.childObjects(path: [], imagePath: imagePath)
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
        /// The component without template arguments; `nil` for a scope made
        /// up on the way to a class only run-time type information shows,
        /// which nothing names.
        var baseName: String?
        var kind: Kind
        var hasMembers: @Sendable () -> Bool
        var children: [String: Node] = [:]

        init(component: String, baseName: String?, kind: Kind, hasMembers: @escaping @Sendable () -> Bool) {
            self.component = component
            self.baseName = baseName
            self.kind = kind
            self.hasMembers = hasMembers
        }

        /// The class template this scope is a specialization of: its base
        /// name, when that differs from the component, which then carries
        /// template arguments. `nil` for any other scope.
        var specializedTemplateName: String? {
            guard let baseName, !baseName.isEmpty, baseName != component else { return nil }
            return baseName
        }

        func insert(_ scope: Scope) {
            guard let component = scope.path.last else { return }
            let kind: Kind = switch scope.kind {
            case .type: .class
            case .namespace, .undetermined: .namespace
            case .function: .function
            }
            let node = Node(component: component, baseName: scope.baseName, kind: kind, hasMembers: scope.hasMembers)
            children[component] = node
            guard kind != .function else { return }
            for child in scope.children {
                node.insert(child)
            }
        }

        /// Puts a class with run-time type information at `path`, below this
        /// node; `baseName` is its last component's. Run-time type information
        /// is stronger evidence than the scope tree's, so an existing
        /// namespace becomes a class.
        func insertClass(at path: ArraySlice<String>, baseName: String) {
            guard let component = path.first else { return }
            let isLast = path.count == 1
            if let node = children[component] {
                if node.kind == .function { return }
                if isLast {
                    node.kind = .class
                    if node.baseName == nil {
                        node.baseName = baseName
                    }
                } else {
                    node.insertClass(at: path.dropFirst(), baseName: baseName)
                }
                return
            }
            if !isLast && CPlusPlusObjectTreeBuilder.isFunctionComponent(component) { return }
            let kind: Kind = isLast || self.kind == .class ? .class : .namespace
            let node = Node(component: component, baseName: isLast ? baseName : nil, kind: kind, hasMembers: { false })
            children[component] = node
            if !isLast {
                node.insertClass(at: path.dropFirst(), baseName: baseName)
            }
        }

        /// The node as an object, `nil` for a function scope and for a
        /// namespace with nothing in it.
        func object(parentPath: [String], imagePath: String) -> RuntimeObject? {
            guard kind != .function else { return nil }
            let path = parentPath + [component]
            let objects = childObjects(path: path, imagePath: imagePath)
            if kind == .namespace, objects.isEmpty, !hasMembers() {
                return nil
            }
            return RuntimeObject(
                name: path.joined(separator: "::"),
                displayName: component,
                kind: kind == .class ? .cPlusPlus(.class) : .cPlusPlus(.namespace),
                imagePath: imagePath,
                children: objects
            )
        }

        /// The objects of this node's children, `path` being this node's own,
        /// with the specializations of each class template gathered under one
        /// `.cPlusPlus(.classTemplate)` object named after the template.
        func childObjects(path: [String], imagePath: String) -> [RuntimeObject] {
            var objects: [RuntimeObject] = []
            var specializationsByTemplateName: [String: [RuntimeObject]] = [:]
            for child in children.values {
                guard let object = child.object(parentPath: path, imagePath: imagePath) else { continue }
                if let templateName = child.specializedTemplateName {
                    specializationsByTemplateName[templateName, default: []].append(object)
                } else {
                    objects.append(object)
                }
            }
            for (templateName, specializations) in specializationsByTemplateName {
                // A sibling already has the template's name: no node, so that
                // no two objects share one.
                guard children[templateName] == nil else {
                    objects.append(contentsOf: specializations)
                    continue
                }
                objects.append(RuntimeObject(
                    name: (path + [templateName]).joined(separator: "::"),
                    displayName: templateName,
                    kind: .cPlusPlus(.classTemplate),
                    imagePath: imagePath,
                    children: specializations.sorted()
                ))
            }
            return objects.sorted()
        }
    }
}
