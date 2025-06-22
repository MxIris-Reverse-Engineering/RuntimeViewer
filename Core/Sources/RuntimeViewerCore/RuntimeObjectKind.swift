public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable, CaseIterable, CustomStringConvertible {
    public enum C: Codable, Hashable, Identifiable, CaseIterable {
        case `struct`
        case `union`
        public var id: Self { self }
    }

    public enum ObjectiveC: Codable, Hashable, Identifiable, CaseIterable {
        case `class`
        case `protocol`
        public var id: Self { self }
    }

    public enum Swift: Codable, Hashable, Identifiable, CaseIterable {
        case `enum`
        case `struct`
        case `class`
        case `protocol`
        public var id: Self { self }
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
            case .class:
                2
            case .protocol:
                3
            }
        case .swift(let swift):
            switch swift {
            case .enum:
                4
            case .struct:
                5
            case .class:
                6
            case .protocol:
                7
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
            case .class:
                "Objective-C Class"
            case .protocol:
                "Objective-C Protocol"
            }
        case .swift(let swift):
            switch swift {
            case .enum:
                "Swift Enum"
            case .struct:
                "Swift Struct"
            case .class:
                "Swift Class"
            case .protocol:
                "Swift Protocol"
            }
        }
    }
}
