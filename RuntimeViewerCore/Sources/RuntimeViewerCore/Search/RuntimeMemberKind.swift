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
