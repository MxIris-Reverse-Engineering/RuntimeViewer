import Foundation

/// What kind of member a `RuntimeMemberDeclaration` is, by language and by the
/// structure it came out of.
///
/// The Find navigator's member mode filters on this. The cases are the
/// structures the sections read — `ObjCClassInfo` / `ObjCProtocolInfo` /
/// `ObjCCategoryInfo` on one side, `TypeDefinition` / `ProtocolDefinition` /
/// `ExtensionDefinition` on the other — not the text they print to, so a
/// subscript is a subscript here even though its declaration text starts
/// with a keyword and carries no name.
public enum RuntimeMemberKind: String, Codable, Hashable, Sendable, CaseIterable {
    case objcProperty
    case objcMethod
    case objcIvar
    case swiftField
    case swiftEnumCase
    case swiftFunction
    case swiftVariable
    case swiftSubscript
    case swiftInitializer

    public var isObjC: Bool {
        switch self {
        case .objcProperty, .objcMethod, .objcIvar: true
        default: false
        }
    }

    public var isSwift: Bool { !isObjC }

    /// Reader-facing label, one per case.
    public var displayName: String {
        switch self {
        case .objcProperty: "ObjC Property"
        case .objcMethod: "ObjC Method"
        case .objcIvar: "ObjC Ivar"
        case .swiftField: "Swift Field"
        case .swiftEnumCase: "Swift Enum Case"
        case .swiftFunction: "Swift Function"
        case .swiftVariable: "Swift Variable"
        case .swiftSubscript: "Swift Subscript"
        case .swiftInitializer: "Swift Initializer"
        }
    }
}

/// One member of a runtime object, as the engine's structured index knows it.
///
/// `lineNumber` is the 1-based line of the member's declaration in the
/// interface the corpus printed (canonical generation options), or `nil`
/// when the printed text could not be aligned with the structure — the
/// member is still searchable, a click then only reaches the type.
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

/// A member whose name matched a member search.
public struct RuntimeMemberMatch: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    public let member: RuntimeMemberDeclaration
    /// Where the query matched inside `member.name`, for highlighting.
    public let matchRangeInName: RuntimeTextRange

    public init(object: RuntimeObject, member: RuntimeMemberDeclaration, matchRangeInName: RuntimeTextRange) {
        self.object = object
        self.member = member
        self.matchRangeInName = matchRangeInName
    }
}

/// The member mode's query: a name fragment, an optional kind filter, case
/// sensitivity and the global result cap.
public struct RuntimeMemberSearchQuery: Hashable, Codable, Sendable {
    public var text: String
    /// `nil` means every kind.
    public var kinds: Set<RuntimeMemberKind>?
    public var isCaseSensitive: Bool
    /// Matches are collected up to this many; scanning goes on to count the
    /// rest, so the summary's total is the real total.
    public var resultLimit: Int

    public init(text: String, kinds: Set<RuntimeMemberKind>? = nil, isCaseSensitive: Bool = false, resultLimit: Int = 1000) {
        self.text = text
        self.kinds = kinds
        self.isCaseSensitive = isCaseSensitive
        self.resultLimit = resultLimit
    }
}
