import Foundation
import RuntimeViewerCore

/// One word of the naming word cloud: how many names hold it, the category
/// it is coloured as, and the names themselves.
public struct NamingWordCount: Hashable, Sendable, Identifiable {
    /// The word in lowercase: what two spellings of it are counted under.
    public let key: String

    /// The word as shown; see `NamingWordTokenizer.displayedWord(_:isLowercased:)`.
    public let word: String

    /// The names that hold it — what its font size stands for.
    public var count: Int { usages.count }

    public let category: NamingWordCategory

    /// The names that hold it, public names before private ones (those
    /// starting with an underscore), each group in alphabetical order.
    public let usages: [NamingWordUsage]

    public var id: String { key }

    public init(key: String, word: String, category: NamingWordCategory, usages: [NamingWordUsage]) {
        self.key = key
        self.word = word
        self.category = category
        self.usages = usages
    }
}

/// A name that holds a word: a type, or a member of one.
public enum NamingWordUsage: Hashable, Sendable {
    case type(RuntimeObject)
    case member(RuntimeObjectMembers.Member, of: RuntimeObject)

    /// The type, or the type that declares the member.
    public var object: RuntimeObject {
        switch self {
        case .type(let object): object
        case .member(_, let object): object
        }
    }

    /// The name as the cloud counts it: a type's own name, without its
    /// enclosing types or generic parameters, or the member's name.
    public var name: String {
        switch self {
        case .type(let object): NamingWordCounter.typeName(of: object)
        case .member(let member, _): member.name
        }
    }

    /// What kind of name it is, in a word: `class`, `protocol`, `struct`,
    /// `property`, `method`, …
    public var kindName: String {
        switch self {
        case .type(let object):
            return NamingWordCounter.kindName(of: object.kind)
        case .member(let member, _):
            switch member.kind {
            case .objcProperty, .swiftVariable, .swiftField: return member.isStatic ? "class property" : "property"
            case .objcMethod, .swiftFunction: return member.isStatic ? "class method" : "method"
            case .objcIvar: return "instance variable"
            case .swiftEnumCase: return "enum case"
            case .swiftSubscript: return "subscript"
            case .swiftInitializer: return "initializer"
            }
        }
    }

    /// Whether the name starts with an underscore, the mark of a private name.
    public var isPrivate: Bool {
        name.hasPrefix("_")
    }
}
