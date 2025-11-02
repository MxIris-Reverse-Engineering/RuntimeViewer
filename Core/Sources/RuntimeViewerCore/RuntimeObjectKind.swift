public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable, CaseIterable, CustomStringConvertible {
    public enum C: Codable, Hashable, Identifiable, CaseIterable {
        case `struct`
        case `union`
        public var id: Self { self }
    }

    
    public enum ObjectiveC: Codable, Hashable, Identifiable, CaseIterable {
        public enum Kind: Codable, Hashable, Identifiable, CaseIterable {
            case `class`
            case `protocol`
            public var id: Self { self }
        }
        case type(Kind)
        case category(Kind)
        public var id: Self { self }
        public static let allCases: [RuntimeObjectKind.ObjectiveC] = {
            Kind.allCases.map { .type($0) } + Kind.allCases.map { .category($0) }
        }()
    }
    
    public enum Swift: Codable, Hashable, Identifiable, CaseIterable {
        public enum Kind: Codable, Hashable, Identifiable, CaseIterable {
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
        public static let allCases: [RuntimeObjectKind.Swift] = {
            Kind.allCases.map { .type($0) } + Kind.allCases.map { .extension($0) } + Kind.allCases.map { .conformance($0) }
        }()
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
                    10
                case .protocol:
                    20
                }
            case .category(let kind):
                switch kind {
                case .class:
                    11
                case .protocol:
                    21
                }
            }
        case .swift(let swift):
            switch swift {
            case .type(let kind):
                switch kind {
                case .enum:
                    30
                case .struct:
                    40
                case .class:
                    50
                case .protocol:
                    60
                case .typeAlias:
                    70
                }
            case .extension(let kind):
                switch kind {
                case .enum:
                    31
                case .struct:
                    41
                case .class:
                    51
                case .protocol:
                    61
                case .typeAlias:
                    71
                }
            case .conformance(let kind):
                switch kind {
                case .enum:
                    32
                case .struct:
                    42
                case .class:
                    52
                case .protocol:
                    62
                case .typeAlias:
                    72
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
