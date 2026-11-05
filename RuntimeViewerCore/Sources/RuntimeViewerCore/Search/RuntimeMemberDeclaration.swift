import Foundation

/// One member of a runtime object, as the engine's structured index knows it.
///
/// `lineNumber` is the 1-based line of the member's declaration in the
/// interface as the search's Generation Options show it (in the corpus, as
/// printed with everything shown), or `nil` when the printed text could not
/// be aligned with the structure — the member is still searchable, a click
/// then only reaches the type.
public struct RuntimeMemberDeclaration: Hashable, Codable, Sendable {
    /// The member's own name: a property, ivar, field or variable name, a
    /// full Objective-C selector (`initWithFrame:`), a Swift function's base
    /// name (`viewDidLoad`), `init` for an initializer, `subscript` for a
    /// subscript.
    public let name: String

    public let kind: RuntimeMemberKind

    /// Class members on the ObjC side (`+` methods, class properties), static
    /// or class members on the Swift side.
    public let isStatic: Bool

    /// The declaration as the interface prints it, trimmed of indentation.
    /// Falls back to `name` when no line could be aligned.
    public let declarationText: String

    public let lineNumber: Int?

    public init(name: String, kind: RuntimeMemberKind, isStatic: Bool, declarationText: String, lineNumber: Int?) {
        self.name = name
        self.kind = kind
        self.isStatic = isStatic
        self.declarationText = declarationText
        self.lineNumber = lineNumber
    }

    /// The same declaration with its line located.
    public func located(at lineNumber: Int, declarationText: String) -> RuntimeMemberDeclaration {
        RuntimeMemberDeclaration(name: name, kind: kind, isStatic: isStatic, declarationText: declarationText, lineNumber: lineNumber)
    }
}
