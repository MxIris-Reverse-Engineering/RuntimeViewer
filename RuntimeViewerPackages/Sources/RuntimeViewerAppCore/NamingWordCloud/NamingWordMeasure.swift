import Foundation
import RuntimeViewerCore

/// What the naming word cloud counts. The raw values are stored.
public enum NamingWordMeasure: String, CaseIterable, Codable, Hashable, Sendable {
    /// The last word of each type name, counted once per type ending in it.
    case typeSuffixes
    /// Every word of each type name, counted once per type holding it.
    case typeWords
    /// Every word of each member name, counted once per member holding it.
    case memberWords
    /// The first word of each method name, counted once per method starting with it.
    case methodFirstWords

    public var title: String {
        switch self {
        case .typeSuffixes: "Type Suffixes"
        case .typeWords: "Type Words"
        case .memberWords: "Member Words"
        case .methodFirstWords: "Method First Words"
        }
    }

    /// Whether the measure reads members, which come from the Find corpus.
    public var readsMembers: Bool {
        switch self {
        case .typeSuffixes, .typeWords: false
        case .memberWords, .methodFirstWords: true
        }
    }

    /// The categories a word of this measure can be coloured as, in the
    /// order a tie is decided in.
    public var categories: [NamingWordCategory] {
        switch self {
        case .typeSuffixes, .typeWords: [.class, .protocol, .valueType]
        case .memberWords: [.property, .method, .otherMember]
        case .methodFirstWords: [.instanceMethod, .classMethod]
        }
    }

    /// What one name of the measure is called, for "Manager — 128 types".
    public func countedNoun(count: Int) -> String {
        switch self {
        case .typeSuffixes, .typeWords: count == 1 ? "type" : "types"
        case .memberWords: count == 1 ? "member" : "members"
        case .methodFirstWords: count == 1 ? "method" : "methods"
        }
    }
}

/// The members Member Words can be limited to. The raw values are stored.
public enum NamingMemberGroup: String, CaseIterable, Codable, Hashable, Sendable {
    /// Objective-C properties and Swift stored and computed properties.
    case properties
    /// Objective-C and Swift methods.
    case methods
    /// Objective-C instance variables.
    case instanceVariables
    /// Swift enum cases.
    case enumCases

    public var title: String {
        switch self {
        case .properties: "Properties"
        case .methods: "Methods"
        case .instanceVariables: "Instance Variables"
        case .enumCases: "Enum Cases"
        }
    }

    /// The group of a member of `kind`, or `nil` for a member the cloud does
    /// not count: Swift initializers and subscripts have no name of their own.
    public init?(_ kind: RuntimeMemberKind) {
        switch kind {
        case .objcProperty, .swiftField, .swiftVariable: self = .properties
        case .objcMethod, .swiftFunction: self = .methods
        case .objcIvar: self = .instanceVariables
        case .swiftEnumCase: self = .enumCases
        case .swiftSubscript, .swiftInitializer: return nil
        }
    }
}

/// The kind of name a word is most representative of, which the cloud
/// colours it by. Each measure uses three at most (`NamingWordMeasure.categories`).
public enum NamingWordCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case `class`
    case `protocol`
    /// Structs, enums and type aliases, and C structs and unions.
    case valueType
    case property
    case method
    /// Objective-C instance variables and Swift enum cases.
    case otherMember
    case instanceMethod
    /// Objective-C class methods and Swift static and class methods.
    case classMethod

    public var title: String {
        switch self {
        case .class: "Classes"
        case .protocol: "Protocols"
        case .valueType: "Value Types"
        case .property: "Properties"
        case .method: "Methods"
        case .otherMember: "Other Members"
        case .instanceMethod: "Instance Methods"
        case .classMethod: "Class Methods"
        }
    }

    /// The position of its colour in the palette: each measure's categories
    /// take the first, second and third colours.
    public var paletteIndex: Int {
        switch self {
        case .class, .property, .instanceMethod: 0
        case .protocol, .method, .classMethod: 1
        case .valueType, .otherMember: 2
        }
    }
}
