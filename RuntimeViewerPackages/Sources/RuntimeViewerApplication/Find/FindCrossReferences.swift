import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// What a Call Hierarchy, Callees or Type References search starts from: one
/// root of its tree. A command names it — Find Call Hierarchy on a member in
/// the content pane, or on a result row — or a term typed into the query field
/// finds it, one root for every method, property, function or type the term
/// matches, as Xcode's call hierarchy gives each matching symbol a root
/// (`-[IDEBatchFindQuerySpecification termSymbolsForWorkspace:useQualifiedNameParser:cancelWhen:]`).
public enum FindCrossReferenceRoot: Hashable, Sendable, Codable {
    /// A member of a type: an Objective-C method or property, a Swift function,
    /// variable, subscript or initializer — every implementation it has, a
    /// property's getter and setter both. `declaration` places it in its
    /// type's interface when it is known.
    case member(RuntimeMemberReference, declaration: RuntimeMemberDeclaration?)
    /// One function, by address: a result row's, which may map to no member.
    case function(RuntimeFunctionReference)
    /// An Objective-C class, or a Swift struct, enum or class.
    case type(RuntimeObject)

    /// Its row's title, and what the query field shows for it.
    public var title: String {
        switch self {
        case .member(let member, _): FindCrossReferenceNaming.title(of: member)
        case .function(let function): FindCrossReferenceNaming.title(of: function)
        case .type(let object): object.displayName
        }
    }

    /// The image it is in.
    public var imagePath: String {
        switch self {
        case .member(let member, _): member.object.imagePath
        case .function(let function): function.imagePath
        case .type(let object): object.imagePath
        }
    }

    /// What the engine is asked about for the calls; `nil` for a type.
    var subject: RuntimeCrossReferenceSubject? {
        switch self {
        case .member(let member, _): .member(member)
        case .function(let function): .function(imagePath: function.imagePath, address: function.address)
        case .type: nil
        }
    }

    /// The type a click on its row goes to.
    var navigationTarget: RuntimeObject? {
        switch self {
        case .member(let member, _): member.object
        case .function(let function): function.member?.object
        case .type(let object): object
        }
    }

    /// The member it stands for, if any.
    var member: RuntimeMemberReference? {
        switch self {
        case .member(let member, _): member
        case .function(let function): function.member
        case .type: nil
        }
    }

    /// Whether `function` is this root's code — the end of a branch that
    /// came back to where it started.
    func contains(_ function: RuntimeFunctionReference) -> Bool {
        switch self {
        case .member(let member, _):
            function.member == member
        case .function(let root):
            root.imagePath == function.imagePath && root.address == function.address
        case .type:
            false
        }
    }

    /// Whether a search in `direction` can start from it: a type for Type
    /// References, a member or a function for the calls.
    func fits(_ direction: FindCrossReferenceDirection) -> Bool {
        switch self {
        case .type: direction == .typeReferences
        case .member, .function: direction != .typeReferences
        }
    }

    /// The types Type References finds references to; see
    /// `RuntimeEngine.typeReferences(to:in:options:reportProgress:)`.
    public static func isReferenceableType(_ object: RuntimeObject) -> Bool {
        switch object.kind {
        case .objc(.type(.class)), .swift(.type(.struct)), .swift(.type(.enum)), .swift(.type(.class)):
            true
        default:
            false
        }
    }

    /// The member kinds with code of their own, which Call Hierarchy and
    /// Callees take as roots: Xcode keeps the properties and the callable
    /// symbols (`-[IDEBatchFindCallHierarchyQuery isValidRootSymbol:]`).
    static let memberKindsWithCode: Set<RuntimeMemberKind> = [
        .objcMethod, .objcProperty, .swiftFunction, .swiftVariable, .swiftSubscript, .swiftInitializer,
    ]
}

/// Find Call Hierarchy, Find Callees or Find Type References asked for from
/// outside the Find page — the content pane, the Inspector, the main menu.
public struct FindCrossReferenceRequest: Hashable, Sendable {
    public let mode: FindMode
    public let root: FindCrossReferenceRoot

    public init(mode: FindMode, root: FindCrossReferenceRoot) {
        self.mode = mode
        self.root = root
    }

    /// The commands a member offers: its callers and its callees, when it has
    /// code.
    public static func requests(for member: RuntimeMemberReference) -> [FindCrossReferenceRequest] {
        guard FindCrossReferenceRoot.memberKindsWithCode.contains(member.kind) else { return [] }
        return [.callHierarchy, .callees].map { FindCrossReferenceRequest(mode: $0, root: .member(member, declaration: nil)) }
    }

    /// The command a type offers: its references, when it is a type they are
    /// found for.
    public static func requests(for object: RuntimeObject) -> [FindCrossReferenceRequest] {
        guard FindCrossReferenceRoot.isReferenceableType(object) else { return [] }
        return [FindCrossReferenceRequest(mode: .typeReferences, root: .type(object))]
    }

    /// `Find Call Hierarchy`, `Find Callees`, `Find Type References`.
    public var title: String { "Find \(mode.title)" }
}

/// One row a cross-reference search found below another: a function, a callee
/// that is no function, the image a type's references come from — or the row
/// that stands in for children not loaded yet.
public struct FindCrossReferenceRow: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        /// A caller, a callee, or a function referencing the type.
        case function(RuntimeFunctionReference)
        /// A callee that is no function: a message, an imported symbol, a type,
        /// an indirect call, code no image holds.
        case target(RuntimeCrossReferenceTarget)
        /// The image a type's references below come from.
        case image(path: String)
        /// Children being loaded, or not loaded yet.
        case loading
        /// Why the children could not be loaded.
        case failure(message: String)
    }

    public let item: Item

    public let direction: FindCrossReferenceDirection

    /// The instructions the row stands for: calls into its parent, calls its
    /// parent makes to it, or references to the type. An image row counts the
    /// references of every function below it.
    public let referenceCount: Int

    /// The surest of those references; `nil` for a row that stands for none.
    public let precision: RuntimeCrossReferencePrecision?

    /// The function stands higher up its own branch already; it is not loaded
    /// again, as Xcode marks and stops at a recursive call
    /// (`-[IDEBatchFindHierarchyResult isRecursive]`).
    public let isRecursive: Bool

    /// Every one of its references is a call to a runtime helper — a retain,
    /// a release, an outlined value operation.
    public let isRuntimeHelperCall: Bool

    public init(item: Item, direction: FindCrossReferenceDirection, referenceCount: Int = 0, precision: RuntimeCrossReferencePrecision? = nil, isRecursive: Bool = false, isRuntimeHelperCall: Bool = false) {
        self.item = item
        self.direction = direction
        self.referenceCount = referenceCount
        self.precision = precision
        self.isRecursive = isRecursive
        self.isRuntimeHelperCall = isRuntimeHelperCall
    }

    /// What the row is titled.
    public var title: String {
        switch item {
        case .function(let function): FindCrossReferenceNaming.title(of: function)
        case .target(let target): FindCrossReferenceNaming.title(of: target)
        case .image(let path): FindScope.imageName(of: path)
        case .loading: "Loading…"
        case .failure(let message): message
        }
    }

    /// `AppKit · 3 calls · by selector`: where the row's function is, how many
    /// instructions it stands for when more than one, and how sure they are
    /// when not exact.
    public var subtitle: String {
        var parts: [String] = []
        switch item {
        case .function(let function):
            parts.append(FindScope.imageName(of: function.imagePath))
        case .target, .image, .loading, .failure:
            break
        }
        if referenceCount > 1 {
            switch direction {
            case .callers, .callees: parts.append("\(referenceCount) calls")
            case .typeReferences: parts.append("\(referenceCount) references")
            }
        }
        switch precision {
        case .matchedBySelector: parts.append("by selector")
        case .candidate: parts.append("candidate")
        case .exact, nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// The function a further level loads for: a function found, unless it
    /// came back around.
    var expandableFunction: RuntimeFunctionReference? {
        guard !isRecursive, direction != .typeReferences, case .function(let function) = item else { return nil }
        return function
    }

    /// The type a click goes to: the one a function implements a member of, or
    /// a type referenced.
    var navigationTarget: RuntimeObject? {
        switch item {
        case .function(let function): function.member?.object
        case .target(.type(_, let object)): object
        case .target, .image, .loading, .failure: nil
        }
    }
}

/// How cross-reference rows name what they show.
public enum FindCrossReferenceNaming {
    /// `-[NSWindow makeKeyAndOrderFront:]`, `+[NSColor redColor]`,
    /// `NSWindow.title`, `ViewGraph.updateOutputs`: a member qualified by its
    /// type, as Xcode titles its call hierarchy rows
    /// (`IDEContainerQualifiedNameForSymbol`). A Swift function's name is its
    /// base name, which stands for all of its overloads.
    public static func title(of member: RuntimeMemberReference) -> String {
        switch member.kind {
        case .objcMethod:
            "\(member.isStatic ? "+" : "-")[\(member.object.displayName) \(member.name)]"
        default:
            "\(member.object.displayName).\(member.name)"
        }
    }

    /// The function as Runtime Viewer prints it, or by address when no symbol
    /// and no metadata names it.
    public static func title(of function: RuntimeFunctionReference) -> String {
        function.displayName ?? unnamedFunctionTitle(address: function.address)
    }

    /// A function nothing names: half the functions in a shared cache.
    public static func unnamedFunctionTitle(address: UInt64) -> String {
        "Unnamed function 0x\(hexadecimal(address))"
    }

    public static func title(of target: RuntimeCrossReferenceTarget) -> String {
        switch target {
        case .function(let function):
            title(of: function)
        case .importedSymbol(let name):
            symbolDisplayName(name)
        case .selector(let name, let receiverClassName):
            // Whether the receiver is the class or an instance of it is not
            // known, so no `-` or `+`.
            receiverClassName.map { "[\($0) \(name)]" } ?? name
        case .type(let name, _):
            name
        case .indirect(let tableOffset, _):
            tableOffset.map { "Indirect call through table offset 0x\(hexadecimal(UInt64(bitPattern: $0)))" } ?? "Indirect call"
        case .unrecognizedCode(let address):
            "Code at 0x\(hexadecimal(address))"
        }
    }

    /// A symbol as the symbol table spells it, without the underscore C names
    /// take there. A Swift mangled name keeps its spelling.
    static func symbolDisplayName(_ name: String) -> String {
        guard name.hasPrefix("_"), !name.hasPrefix("_$") else { return name }
        return String(name.dropFirst())
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

extension FindResultNode {
    /// What Find Call Hierarchy, Find Callees or Find Type References on this
    /// row starts from: the row's function, member or type. Xcode offers Find
    /// Call Hierarchy on its result rows the same way, rooting a new query at
    /// the row's symbol (`-[IDEFindNavigator contextMenuFocusedCallHierarchySymbol]`).
    public var crossReferenceRoot: FindCrossReferenceRoot? {
        switch content {
        case .crossReferenceRoot(let root, _):
            return root
        case .crossReference(let row):
            switch row.item {
            case .function(let function):
                return .function(function)
            case .target(.type(_, let object?)) where FindCrossReferenceRoot.isReferenceableType(object):
                return .type(object)
            case .target, .image, .loading, .failure:
                return nil
            }
        case .member(let match):
            guard FindCrossReferenceRoot.memberKindsWithCode.contains(match.member.kind) else { return nil }
            let member = RuntimeMemberReference(object: match.object, name: match.member.name, kind: match.member.kind, isStatic: match.member.isStatic)
            return .member(member, declaration: match.member)
        case .object(let object), .relationship(_, let object?):
            return FindCrossReferenceRoot.isReferenceableType(object) ? .type(object) : nil
        case .textMatch, .relationship(_, nil):
            return nil
        }
    }

    /// The cross-reference modes a command can run for this row.
    public var crossReferenceModes: [FindMode] {
        switch crossReferenceRoot {
        case .member, .function: [.callHierarchy, .callees]
        case .type: [.typeReferences]
        case nil: []
        }
    }

    /// Whether the row belongs to a cross-reference tree.
    var isCrossReferenceRow: Bool {
        switch content {
        case .crossReferenceRoot, .crossReference: true
        case .object, .textMatch, .member, .relationship: false
        }
    }
}

extension DocumentState {
    /// What Find Call Hierarchy, Find Callees or Find Type References in the
    /// main menu acts on: the member at the content pane's insertion point,
    /// or the type on screen; `nil` disables the command.
    public func crossReferenceRequest(_ mode: FindMode) -> FindCrossReferenceRequest? {
        switch mode.crossReferenceDirection {
        case .callers?, .callees?:
            guard let cursorMember, cursorMember.object == selectedRuntimeObject else { return nil }
            return FindCrossReferenceRequest.requests(for: cursorMember).first { $0.mode == mode }
        case .typeReferences?:
            guard let selectedRuntimeObject else { return nil }
            return FindCrossReferenceRequest.requests(for: selectedRuntimeObject).first
        case nil:
            return nil
        }
    }
}

/// Where a click on a cross-reference row goes — in the Find navigator and in
/// the Inspector's References tab alike.
@MainActor
enum FindCrossReferenceNavigation {
    /// Opens `object` in place or in a new tab, flashing `highlight` once it
    /// is on screen.
    static func open(_ object: RuntimeObject, highlighting highlight: ContentHighlightRequest?, inNewTab: Bool, in documentState: DocumentState) {
        switch (inNewTab, highlight) {
        case (false, nil):
            documentState.selectionRouter.trigger(.push(object))
        case (false, let highlight?):
            documentState.selectionRouter.trigger(.pushHighlighting(object, highlight))
        case (true, nil):
            documentState.selectionRouter.trigger(.openInNewTab(object))
        case (true, let highlight?):
            documentState.selectionRouter.trigger(.openInNewTabHighlighting(object, highlight))
        }
    }

    /// Goes to the member's declaration. A row that found a function knows its
    /// member but not where the interface declares it; the corpus of its image
    /// knows, and the click waits for it — the task returned, which the next
    /// click cancels. Without a corpus the click reaches the type, as a member
    /// search's row with no line does.
    static func open(_ member: RuntimeMemberReference, declaration: RuntimeMemberDeclaration?, inNewTab: Bool, in documentState: DocumentState, generationOptions: RuntimeObjectInterface.GenerationOptions) -> Task<Void, Never>? {
        if let declaration, declaration.lineNumber != nil {
            open(member.object, highlighting: highlight(for: member, declaration: declaration), inNewTab: inNewTab, in: documentState)
            return nil
        }
        let engine = documentState.runtimeEngine
        return Task { [weak documentState] in
            let declaration = try? await FindCrossReferenceRootResolver.declaration(of: member, engine: engine, generationOptions: generationOptions)
            guard let documentState, !Task.isCancelled else { return }
            open(member.object, highlighting: declaration.flatMap { highlight(for: member, declaration: $0) }, inNewTab: inNewTab, in: documentState)
        }
    }

    /// The member's declaration, flashed as a member search's row flashes it.
    static func highlight(for member: RuntimeMemberReference, declaration: RuntimeMemberDeclaration) -> ContentHighlightRequest? {
        guard let lineNumber = declaration.lineNumber else { return nil }
        let match = RuntimeMemberMatch(object: member.object, member: declaration, matchRangeInName: RuntimeTextRange(location: 0, length: (declaration.name as NSString).length))
        return ContentHighlightRequest(
            lineNumber: lineNumber,
            lineText: declaration.declarationText,
            matchRangeInLine: FindResultNode.nameRange(of: match).map { RuntimeTextRange(location: $0.location, length: $0.length) },
            query: declaration.name,
            matchMode: .matchingWord,
            isCaseSensitive: true
        )
    }
}
