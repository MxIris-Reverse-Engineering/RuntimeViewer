import CrossReferenceAnalysis
import Demangling
import ObjectiveC
import RuntimeViewerCore

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
