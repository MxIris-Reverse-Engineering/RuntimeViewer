public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable, CaseIterable, CustomStringConvertible, Sendable {
    public enum C: Codable, Hashable, Identifiable, CaseIterable, Sendable {
        case `struct`
        case `union`
        
        public var id: Self { self }
    }

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

    case c(C)
    case objc(ObjectiveC)
    case swift(Swift)

    public var id: Self { self }

    private var level: Int {
        switch self {
        case .c(let c):
            switch c {
            case .struct:
                0
            case .union:
                1
            }
        case .objc(let objectiveC):
            switch objectiveC {
            case .type(let kind):
                switch kind {
                case .class:
                    2
                case .protocol:
                    3
                }
            case .category(let kind):
                switch kind {
                case .class:
                    4
                case .protocol:
                    5
                }
            }
        case .swift(let swift):
            switch swift {
            case .type(let kind):
                switch kind {
                case .enum:
                    6
                case .struct:
                    7
                case .class:
                    8
                case .protocol:
                    9
                case .typeAlias:
                    10
                }
            case .extension(let kind):
                switch kind {
                case .enum:
                    11
                case .struct:
                    12
                case .class:
                    13
                case .protocol:
                    14
                case .typeAlias:
                    15
                }
            case .conformance(let kind):
                switch kind {
                case .enum:
                    16
                case .struct:
                    17
                case .class:
                    18
                case .protocol:
                    19
                case .typeAlias:
                    20
                }
            }
        }
    }

    public static func < (lhs: RuntimeObjectKind, rhs: RuntimeObjectKind) -> Bool {
        lhs.level < rhs.level
    }

    public static let allCases: [RuntimeObjectKind] = {
        var cases: [RuntimeObjectKind] = []
        cases.append(contentsOf: C.allCases.map { RuntimeObjectKind.c($0) })
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
        }
    }
}
