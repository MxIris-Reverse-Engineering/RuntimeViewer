public enum RuntimeObjectKind: Codable, Hashable, Identifiable, Comparable {
    public enum C: Codable, Hashable, Identifiable {
        case `struct`
        case `union`
        public var id: Self { self }
    }

    public enum ObjectiveC: Codable, Hashable, Identifiable {
        case `class`
        case `protocol`
        public var id: Self { self }
    }

    public enum Swift: Codable, Hashable, Identifiable {
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
}
