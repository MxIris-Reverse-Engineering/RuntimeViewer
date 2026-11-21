import Foundation
import Semantic

/// Prints a C++ class or namespace as a pseudo-header.
///
/// A class prints its bases, then each vtable's slots in order — the primary
/// table first — then its constructors and destructors, its other member
/// functions, its variables and the types declared in it. A namespace prints
/// its functions, its variables and what is declared in it. Slot numbers,
/// addresses and whether a slot overrides or inherits its base's function go
/// in comments.
///
/// Prints only what the image says: Itanium mangling records a return type
/// for a function template specialization alone, does not tell a static
/// member from another, and records no access level, so none of these is
/// guessed. Every class and namespace a declaration names is spelled in
/// full, so the content pane can look a token's text up as the object it
/// names.
///
/// Works on the plain values below rather than MachOKitExtensions' types,
/// whose initializers are not public, so its rules are tested on made-up
/// declarations; `RuntimeCPlusPlusSection` makes the values.
struct CPlusPlusInterfacePrinter {
    /// A function's name as a declaration prints it.
    struct Function: Hashable, Sendable {
        /// Only a function template specialization's mangling has one.
        var returnType: String?
        /// The name with its template arguments: `push_back`, `~vector`,
        /// `get<int>`.
        var name: String
        /// `(int, char const*)`; `nil` prints none.
        var parameters: String?
        /// `const`, `volatile`, `&`, `&&`, in that order.
        var qualifiers: [String]

        init(returnType: String? = nil, name: String, parameters: String? = "()", qualifiers: [String] = []) {
            self.returnType = returnType
            self.name = name
            self.parameters = parameters
            self.qualifiers = qualifiers
        }
    }

    /// A function or a variable of the image, at one address or several —
    /// a constructor's or a destructor's variants share a declaration.
    struct Member: Hashable, Sendable {
        var function: Function
        var addresses: [String]
    }

    struct Variable: Hashable, Sendable {
        var name: String
        var addresses: [String]
    }

    struct Base: Hashable, Sendable {
        var qualifiedName: String
        var isVirtual: Bool
        var isPublic: Bool
    }

    struct Slot: Hashable, Sendable {
        enum Implementation: Hashable, Sendable {
            /// A function of this image.
            case address(String)
            /// A function a file binds from another library.
            case imported(installName: String?)
            /// A function of another image of the cache or the process.
            case otherImage(address: String)
            case pureVirtual
            case deletedVirtual
        }

        enum Relation: Hashable, Sendable {
            case overrides(String)
            case inherited(String)
        }

        var index: Int
        /// `nil` for a slot neither its implementation nor a base names.
        var function: Function?
        var implementation: Implementation
        var relation: Relation?
    }

    struct Table: Hashable, Sendable {
        var offsetToTop: Int
        /// The base whose subobject uses a secondary table, when known.
        var subobjectClassName: String?
        var slots: [Slot]

        var isPrimary: Bool { offsetToTop == 0 }
    }

    /// A class or a namespace declared inside the one printed.
    struct Declared: Hashable, Sendable {
        var qualifiedName: String
        var isClass: Bool
    }

    struct ClassDeclaration: Sendable {
        var qualifiedName: String
        var imageName: String
        var typeInfoAddress: String?
        var virtualTableAddress: String?
        /// No symbol of the image names the class: only its run-time type
        /// information shows it.
        var isRecoveredFromTypeInfoOnly = false
        /// Its typeinfo is a copy each image keeps, compared by name.
        var hasNonUniqueTypeInfo = false
        var bases: [Base] = []
        var tables: [Table] = []
        var constructorsAndDestructors: [Member] = []
        var memberFunctions: [Member] = []
        var variables: [Variable] = []
        var declaredTypes: [Declared] = []
    }

    struct NamespaceDeclaration: Sendable {
        var qualifiedName: String
        var imageName: String
        var isGlobal = false
        /// No symbol name shows whether the scope is a namespace or a type.
        var isUndetermined = false
        var functions: [Member] = []
        var variables: [Variable] = []
        var declared: [Declared] = []
    }

    /// Whether comments carry addresses, as `ObjCGenerationOptions`'
    /// `addMethodIMPAddressComments` decides for an Objective-C header.
    var showsAddresses: Bool

    // MARK: - Class

    func interface(of declaration: ClassDeclaration) -> SemanticString {
        var string = SemanticString()
        var headerParts = [declaration.imageName]
        if showsAddresses, let typeInfoAddress = declaration.typeInfoAddress {
            headerParts.append("typeinfo \(typeInfoAddress)")
        }
        if showsAddresses, let virtualTableAddress = declaration.virtualTableAddress {
            headerParts.append("vtable \(virtualTableAddress)")
        }
        appendCommentLine(headerParts.joined(separator: " · "), to: &string)
        if declaration.isRecoveredFromTypeInfoOnly {
            appendCommentLine("Recovered from run-time type information only: no symbol of the image names the class.", to: &string)
        }
        if declaration.hasNonUniqueTypeInfo {
            appendCommentLine("Its typeinfo is not unique: each image keeps a copy, compared by name.", to: &string)
        }

        string.append("class", type: .keyword)
        string.append(" ", type: .standard)
        string.append(declaration.qualifiedName, type: .type(.class, .declaration))
        for (index, base) in declaration.bases.enumerated() {
            string.append(index == 0 ? " : " : ", ", type: .standard)
            if base.isVirtual {
                string.append("virtual", type: .keyword)
                string.append(" ", type: .standard)
            }
            if base.isPublic {
                string.append("public", type: .keyword)
                string.append(" ", type: .standard)
            } else {
                string.append("/* not public */", type: .comment)
                string.append(" ", type: .standard)
            }
            string.append(base.qualifiedName, type: .type(.class, .name))
        }
        string.append(" {\n", type: .standard)

        var sections: [SemanticString] = []
        for table in declaration.tables where !table.slots.isEmpty {
            sections.append(tableSection(table))
        }
        if !declaration.constructorsAndDestructors.isEmpty {
            sections.append(memberSection(title: "Constructors and destructors", members: declaration.constructorsAndDestructors))
        }
        if !declaration.memberFunctions.isEmpty {
            sections.append(memberSection(title: "Member functions", members: declaration.memberFunctions))
        }
        if !declaration.variables.isEmpty {
            sections.append(variableSection(declaration.variables))
        }
        if !declaration.declaredTypes.isEmpty {
            sections.append(declaredSection(title: "Types", declared: declaration.declaredTypes))
        }
        append(sections, to: &string)
        string.append("};", type: .standard)
        return string
    }

    // MARK: - Namespace

    func interface(of declaration: NamespaceDeclaration) -> SemanticString {
        var string = SemanticString()
        appendCommentLine(declaration.imageName, to: &string)
        var sections: [SemanticString] = []
        if !declaration.functions.isEmpty {
            sections.append(memberSection(title: "Functions", members: declaration.functions, isIndented: !declaration.isGlobal))
        }
        if !declaration.variables.isEmpty {
            sections.append(variableSection(declaration.variables, isIndented: !declaration.isGlobal))
        }
        if !declaration.declared.isEmpty {
            sections.append(declaredSection(title: "Declared here", declared: declaration.declared, isIndented: !declaration.isGlobal))
        }
        if declaration.isGlobal {
            appendCommentLine("Global namespace", to: &string)
            append(sections, to: &string)
            return string
        }
        if declaration.isUndetermined {
            appendCommentLine("No symbol name shows whether this is a namespace or a type.", to: &string)
        }
        string.append("namespace", type: .keyword)
        string.append(" ", type: .standard)
        string.append(declaration.qualifiedName, type: .type(.other, .declaration))
        string.append(" {\n", type: .standard)
        append(sections, to: &string)
        string.append("}", type: .standard)
        return string
    }

    // MARK: - Sections

    private func tableSection(_ table: Table) -> SemanticString {
        var string = SemanticString()
        if table.isPrimary {
            appendCommentLine("Virtual functions (primary vtable)", indented: true, to: &string)
        } else {
            appendCommentLine("Virtual functions (secondary vtable for \(table.subobjectClassName ?? "an unknown base"), offset-to-top \(table.offsetToTop))", indented: true, to: &string)
        }
        for group in Self.mergedSlots(table.slots) {
            string.append(Self.indentation, type: .standard)
            string.append("virtual", type: .keyword)
            string.append(" ", type: .standard)
            if let function = group.first?.function {
                append(function, to: &string)
            } else {
                string.append("/* unnamed */", type: .comment)
            }
            switch group.first?.implementation {
            case .pureVirtual:
                string.append(" = ", type: .standard)
                string.append("0", type: .numeric)
            case .deletedVirtual:
                string.append(" = ", type: .standard)
                string.append("delete", type: .keyword)
            default:
                break
            }
            string.append(";", type: .standard)
            string.append("  " + "// " + slotComment(group), type: .comment)
            string.append("\n", type: .standard)
        }
        return string
    }

    private func slotComment(_ group: [Slot]) -> String {
        var parts: [String] = []
        if let first = group.first, let last = group.last, first.index != last.index {
            parts.append("slots \(first.index)–\(last.index)")
        } else {
            parts.append("slot \(group.first?.index ?? 0)")
        }
        let addresses = group.compactMap { slot -> String? in
            if case .address(let address) = slot.implementation { return address }
            return nil
        }
        if showsAddresses, !addresses.isEmpty {
            parts.append(addresses.joined(separator: ", "))
        }
        switch group.first?.implementation {
        case .imported(let installName):
            parts.append(installName.map { "imported from \($0)" } ?? "imported")
        case .otherImage(let address):
            parts.append(showsAddresses ? "in another image at \(address)" : "in another image")
        default:
            break
        }
        switch group.first?.relation {
        case .overrides(let className):
            parts.append("overrides \(className)")
        case .inherited(let className):
            parts.append("inherited from \(className)")
        case nil:
            break
        }
        return parts.joined(separator: "  ")
    }

    /// Consecutive slots of one named function: the two a virtual destructor
    /// takes, its complete and its deleting variant.
    static func mergedSlots(_ slots: [Slot]) -> [[Slot]] {
        var groups: [[Slot]] = []
        for slot in slots {
            if let previous = groups.last?.last,
               let function = slot.function, function == previous.function,
               slot.relation == previous.relation {
                groups[groups.count - 1].append(slot)
            } else {
                groups.append([slot])
            }
        }
        return groups
    }

    private func memberSection(title: String, members: [Member], isIndented: Bool = true) -> SemanticString {
        var string = SemanticString()
        appendCommentLine(title, indented: isIndented, to: &string)
        for member in members {
            if isIndented {
                string.append(Self.indentation, type: .standard)
            }
            append(member.function, to: &string)
            string.append(";", type: .standard)
            if showsAddresses, !member.addresses.isEmpty {
                string.append("  // " + member.addresses.joined(separator: ", "), type: .comment)
            }
            string.append("\n", type: .standard)
        }
        return string
    }

    private func variableSection(_ variables: [Variable], isIndented: Bool = true) -> SemanticString {
        var string = SemanticString()
        appendCommentLine("Variables", indented: isIndented, to: &string)
        for variable in variables {
            if isIndented {
                string.append(Self.indentation, type: .standard)
            }
            string.append(variable.name, type: .member(.declaration))
            string.append(";", type: .standard)
            if showsAddresses, !variable.addresses.isEmpty {
                string.append("  // " + variable.addresses.joined(separator: ", "), type: .comment)
            }
            string.append("\n", type: .standard)
        }
        return string
    }

    private func declaredSection(title: String, declared: [Declared], isIndented: Bool = true) -> SemanticString {
        var string = SemanticString()
        appendCommentLine(title, indented: isIndented, to: &string)
        for entry in declared {
            if isIndented {
                string.append(Self.indentation, type: .standard)
            }
            if entry.isClass {
                string.append("class", type: .keyword)
                string.append(" ", type: .standard)
                string.append(entry.qualifiedName, type: .type(.class, .name))
                string.append(";", type: .standard)
            } else {
                string.append("namespace", type: .keyword)
                string.append(" ", type: .standard)
                string.append(entry.qualifiedName, type: .type(.other, .name))
                string.append(" {}", type: .standard)
            }
            string.append("\n", type: .standard)
        }
        return string
    }

    // MARK: - Pieces

    private static let indentation = "    "

    private func append(_ function: Function, to string: inout SemanticString) {
        if let returnType = function.returnType {
            string.append(returnType + " ", type: .standard)
        }
        string.append(function.name, type: .function(.declaration))
        if let parameters = function.parameters {
            string.append(parameters, type: .standard)
        }
        for qualifier in function.qualifiers {
            string.append(" ", type: .standard)
            if qualifier.first?.isLetter == true {
                string.append(qualifier, type: .keyword)
            } else {
                string.append(qualifier, type: .standard)
            }
        }
    }

    private func appendCommentLine(_ text: String, indented: Bool = false, to string: inout SemanticString) {
        if indented {
            string.append(Self.indentation, type: .standard)
        }
        string.append("// " + text, type: .comment)
        string.append("\n", type: .standard)
    }

    /// The sections, a blank line between two.
    private func append(_ sections: [SemanticString], to string: inout SemanticString) {
        for (index, section) in sections.enumerated() {
            if index > 0 {
                string.append("\n", type: .standard)
            }
            string.append(section)
        }
    }
}
