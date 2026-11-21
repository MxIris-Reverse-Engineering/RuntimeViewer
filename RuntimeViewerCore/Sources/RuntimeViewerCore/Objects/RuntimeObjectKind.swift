import SwiftStdlibToolbox

//@AssociatedValue(.public)
//@CaseCheckable(.public)
public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable, CaseIterable, CustomStringConvertible, Sendable {
    public enum C: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        case `struct`
        case `union`
        
        public var id: Self { self }
    }
//    @AssociatedValue(.public)
//    @CaseCheckable(.public)
    public enum ObjectiveC: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        public enum Kind: Codable, Hashable, Identifiable, CaseIterable, Sendable {
            case `class`
            case `protocol`
            public var id: Self { self }
        }

        case type(Kind)
        case category(Kind)
        
        public var id: Self { self }
        
        public static let allCases: [RuntimeObjectKind.ObjectiveC] = Kind.allCases.map { .type($0) } + Kind.allCases.map { .category($0) }
    }
//    @AssociatedValue(.public)
//    @CaseCheckable(.public)
    public enum Swift: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        public enum Kind: Codable, Hashable, Identifiable, CaseIterable, Sendable {
            case `enum`
            case `struct`
            case `class`
            case `protocol`
            case `typeAlias`
            public var id: Self { self }
        }

        case type(Kind)
        case `extension`(Kind)
        case conformance(Kind)
        
        public var id: Self { self }
        
        public static let allCases: [RuntimeObjectKind.Swift] = Kind.allCases.map { .type($0) } + Kind.allCases.map { .extension($0) } + Kind.allCases.map { .conformance($0) }
    }

    /// A C++ entity an image's symbols or run-time type information show.
    /// Itanium mangling does not tell a `struct` from a `class`, so every C++
    /// type is a class.
    public enum CPlusPlus: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        case `class`
        case namespace

        public var id: Self { self }
    }

    case c(C)
    case objc(ObjectiveC)
    case swift(Swift)
    case cPlusPlus(CPlusPlus)

    public var id: Self { self }

    /// The order of the sidebar's kind sections, the jump bar's groups and the
    /// image page's counts: C, then C++, Objective-C and Swift. Private and used
    /// by `<` alone — never encoded (`Codable` is synthesized from the case
    /// names), so renumbering it breaks no peer and no stored value.
    private var level: Int {
        switch self {
        case .c(let c):
            switch c {
            case .struct:
                0
            case .union:
                1
            }
        case .cPlusPlus(let cPlusPlus):
            switch cPlusPlus {
            case .class:
                2
            case .namespace:
                3
            }
        case .objc(let objectiveC):
            switch objectiveC {
            case .type(let kind):
                switch kind {
                case .class:
                    4
                case .protocol:
                    5
                }
            case .category(let kind):
                switch kind {
                case .class:
                    6
                case .protocol:
                    7
                }
            }
        case .swift(let swift):
            switch swift {
            case .type(let kind):
                switch kind {
                case .enum:
                    8
                case .struct:
                    9
                case .class:
                    10
                case .protocol:
                    11
                case .typeAlias:
                    12
                }
            case .extension(let kind):
                switch kind {
                case .enum:
                    13
                case .struct:
                    14
                case .class:
                    15
                case .protocol:
                    16
                case .typeAlias:
                    17
                }
            case .conformance(let kind):
                switch kind {
                case .enum:
                    18
                case .struct:
                    19
                case .class:
                    20
                case .protocol:
                    21
                case .typeAlias:
                    22
                }
            }
        }
    }

    public static func < (leftKind: RuntimeObjectKind, rightKind: RuntimeObjectKind) -> Bool {
        leftKind.level < rightKind.level
    }

    /// In `level` order.
    public static let allCases: [RuntimeObjectKind] = {
        var cases: [RuntimeObjectKind] = []
        cases.append(contentsOf: C.allCases.map { RuntimeObjectKind.c($0) })
        cases.append(contentsOf: CPlusPlus.allCases.map { RuntimeObjectKind.cPlusPlus($0) })
        cases.append(contentsOf: ObjectiveC.allCases.map { RuntimeObjectKind.objc($0) })
        cases.append(contentsOf: Swift.allCases.map { RuntimeObjectKind.swift($0) })
        return cases
    }()

    public var description: String {
        switch self {
        case .c(let c):
            switch c {
            case .struct:
                "C Struct"
            case .union:
                "C Union"
            }
        case .objc(let objectiveC):
            switch objectiveC {
            case .type(let kind):
                switch kind {
                case .class:
                    "Objective-C Class"
                case .protocol:
                    "Objective-C Protocol"
                }
            case .category(let kind):
                switch kind {
                case .class:
                    "Objective-C Class Category"
                case .protocol:
                    "Objective-C Protocol Category"
                }
            }
        case .swift(let swift):
            switch swift {
            case .type(let kind):
                switch kind {
                case .enum:
                    "Swift Enum"
                case .struct:
                    "Swift Struct"
                case .class:
                    "Swift Class"
                case .protocol:
                    "Swift Protocol"
                case .typeAlias:
                    "Swift TypeAlias"
                }
            case .extension(let kind):
                switch kind {
                case .enum:
                    "Swift Enum Extension"
                case .struct:
                    "Swift Struct Extension"
                case .class:
                    "Swift Class Extension"
                case .protocol:
                    "Swift Protocol Extension"
                case .typeAlias:
                    "Swift TypeAlias Extension"
                }
            case .conformance(let kind):
                switch kind {
                case .enum:
                    "Swift Enum Conformance"
                case .struct:
                    "Swift Struct Conformance"
                case .class:
                    "Swift Class Conformance"
                case .protocol:
                    "Swift Protocol Conformance"
                case .typeAlias:
                    "Swift TypeAlias Conformance"
                }
            }
        case .cPlusPlus(let cPlusPlus):
            switch cPlusPlus {
            case .class:
                "C++ Class"
            case .namespace:
                "C++ Namespace"
            }
        }
    }
    
    public var isC: Bool {
        switch self {
        case .c: return true
        default: return false
        }
    }
    
    public var isObjC: Bool {
        switch self {
        case .objc: return true
        default: return false
        }
    }
    
    public var isSwift: Bool {
        switch self {
        case .swift: return true
        default: return false
        }
    }

    public var isCPlusPlus: Bool {
        switch self {
        case .cPlusPlus: return true
        default: return false
        }
    }
}
