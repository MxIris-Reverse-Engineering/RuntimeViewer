import CrossReferenceAnalysis
import Demangling
import ObjectiveC
import RuntimeViewerCore

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
