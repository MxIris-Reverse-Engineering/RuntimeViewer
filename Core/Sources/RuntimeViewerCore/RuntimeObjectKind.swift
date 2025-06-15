public enum RuntimeObjectKind: Codable, Hashable, Identifiable {
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
}
