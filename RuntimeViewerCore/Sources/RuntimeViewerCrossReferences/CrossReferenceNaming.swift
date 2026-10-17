import CrossReferenceAnalysis
import Demangling

/// An Objective-C method's name, split: `-[NSWindow(NSWindowTabbing) addTabbedWindow:ordered:]`
/// is an instance method of `NSWindow` with that selector.
struct ObjectiveCMethodName: Hashable, Sendable {
    let className: String
    let selector: String
    let isClassMethod: Bool

    /// The name a symbol table or a method list gives: `-[Class selector]`,
    /// `+[Class selector]`, with an optional category after the class.
    init?(symbol: String) {
        let isClassMethod: Bool
        if symbol.hasPrefix("-[") {
            isClassMethod = false
        } else if symbol.hasPrefix("+[") {
            isClassMethod = true
        } else {
            return nil
        }
        guard symbol.hasSuffix("]") else { return nil }
        let body = symbol.dropFirst(2).dropLast()
        guard let space = body.firstIndex(of: " ") else { return nil }
        var classPart = body[..<space]
        if let categoryStart = classPart.firstIndex(of: "(") {
            classPart = classPart[..<categoryStart]
        }
        let selector = body[body.index(after: space)...]
        guard !classPart.isEmpty, !selector.isEmpty else { return nil }
        self.className = String(classPart)
        self.selector = String(selector)
        self.isClassMethod = isClassMethod
    }

    init(className: String, selector: String, isClassMethod: Bool) {
        self.className = className
        self.selector = selector
        self.isClassMethod = isClassMethod
    }

    /// Every Objective-C method `function` is, by its names: one, or several
    /// when identical code folding gave one body to several methods.
    static func all(of function: CodeFunction?) -> [ObjectiveCMethodName] {
        guard let function else { return [] }
        var names: [ObjectiveCMethodName] = []
        switch function.name {
        case .symbol(let symbol)?:
            if let name = ObjectiveCMethodName(symbol: symbol) { names.append(name) }
        case .objectiveCMethod(let className, let selector, let isClassMethod)?:
            names.append(ObjectiveCMethodName(className: className, selector: selector, isClassMethod: isClassMethod))
        case .swiftMetadata?, nil:
            break
        }
        names.append(contentsOf: function.foldedSymbolNames.compactMap(ObjectiveCMethodName.init(symbol:)))
        return names
    }

    /// Root classes, whose instance methods a class object reaches too: a
    /// metaclass's superclass chain ends in its root class.
    ///
    /// By name, because a query reads classes of images that are not loaded,
    /// where the Objective-C runtime has nothing to ask. Other root classes
    /// exist; a send to a class object is then reported as unable to reach
    /// their instance methods, which is wrong only for that rare case.
    var isOfRootClass: Bool {
        className == "NSObject" || className == "NSProxy"
    }
}

/// How names reach the wire.
enum CrossReferenceNaming {
    /// Swift symbols print the way Runtime Viewer shows a declaration in a
    /// list: qualified, with argument labels, without types —
    /// `SwiftUI.ViewGraph.updateOutputs(at:)`.
    private static let swiftDisplayOptions = DemangleOptions.simplified.union(.displayModuleNames)

    /// The name a symbol is shown by. An Objective-C method stays as it is,
    /// a Swift symbol is demangled, a C symbol loses the underscore the C
    /// compiler prefixed it with; anything that does not demangle is shown
    /// as the symbol table spells it.
    static func displayName(forSymbol symbol: String) -> String {
        if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") { return symbol }
        let name = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        guard name.hasPrefix("$s") || name.hasPrefix("$S") || name.hasPrefix("$e") || name.hasPrefix("_T0") else {
            return name
        }
        // Transient: the tree is printed and dropped. `demangleAsNode` interns
        // every node into a cache that never evicts, and a query names
        // thousands of functions.
        guard let node = try? demangleAsNodeTransient(name) else { return name }
        let printed = node.print(using: swiftDisplayOptions)
        return printed.isEmpty ? name : printed
    }

    /// The name a Swift type's key is shown by: `7SwiftUI4TextV` is
    /// `SwiftUI.Text`. A key is a type's mangling without `$s` or a suffix;
    /// as the type's metadata symbol it demangles, and the type is printed.
    static func displayName(forTypeKey key: String) -> String {
        guard let node = try? demangleAsNodeTransient("$s" + key + "N"),
              let typeNode = node.children.first?.children.first
        else { return key }
        let printed = typeNode.print(using: swiftDisplayOptions)
        return printed.isEmpty ? key : printed
    }

    /// The name an Objective-C class is shown by: its runtime name, or — for
    /// a Swift class, whose runtime name is `_TtC7SwiftUI13PinnedBarView` —
    /// the Swift name it stands for.
    static func displayName(forClassName className: String) -> String {
        guard className.hasPrefix("_Tt"), let node = try? demangleAsNodeTransient(className) else { return className }
        let printed = node.print(using: swiftDisplayOptions)
        return printed.isEmpty ? className : printed
    }
}

/// Turns the analysis's functions into the wire's, demangling each name once
/// per query.
struct FunctionReferenceBuilder {
    let imagePaths: [String]
    private var displayNamesBySymbol: [String: String] = [:]

    init(imagePaths: [String]) {
        self.imagePaths = imagePaths
    }

    mutating func reference(for function: CodeFunction, member: RuntimeMemberReference? = nil) -> RuntimeFunctionReference {
        let symbolName: String?
        let displayName: String?
        switch function.name {
        case .symbol(let symbol)?:
            symbolName = symbol
            displayName = cachedDisplayName(forSymbol: symbol)
        case .objectiveCMethod(let className, let selector, let isClassMethod)?:
            symbolName = nil
            displayName = "\(isClassMethod ? "+" : "-")[\(className) \(selector)]"
        case .swiftMetadata(let mangledName)?:
            // Rebuilt from the metadata, not read from the symbol table: a
            // complete mangled name that demangles like a symbol.
            symbolName = nil
            displayName = cachedDisplayName(forSymbol: mangledName)
        case nil:
            symbolName = nil
            displayName = nil
        }
        return RuntimeFunctionReference(
            imagePath: imagePaths[function.location.imageIndex],
            address: function.location.address,
            displayName: displayName,
            symbolName: symbolName,
            member: member,
            foldedSymbolCount: function.foldedSymbolNames.count
        )
    }

    /// Code at `location` that starts no function the analysis knows.
    func unnamedReference(at location: CodeLocation) -> RuntimeFunctionReference {
        RuntimeFunctionReference(
            imagePath: imagePaths[location.imageIndex],
            address: location.address,
            displayName: nil,
            symbolName: nil,
            member: nil,
            foldedSymbolCount: 0
        )
    }

    private mutating func cachedDisplayName(forSymbol symbol: String) -> String {
        if let known = displayNamesBySymbol[symbol] { return known }
        let displayName = CrossReferenceNaming.displayName(forSymbol: symbol)
        displayNamesBySymbol[symbol] = displayName
        return displayName
    }
}
