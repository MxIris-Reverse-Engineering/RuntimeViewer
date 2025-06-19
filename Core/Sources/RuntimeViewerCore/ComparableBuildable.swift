import Foundation

@frozen public enum ComparisonResult {
    case ascending
    case descending
    case equal
}

public struct ComparableDefinition<T> {
    let steps: [ComparisonStep<T>]

    func compare(_ lhs: T, _ rhs: T) -> ComparisonResult {
        for step in steps {
            let result = step.compare(lhs, rhs)
            if result != .equal {
                return result
            }
        }
        return .equal
    }

    var lessThan: (T, T) -> Bool {
        return { lhs, rhs in
            self.compare(lhs, rhs) == .ascending
        }
    }

    var equalTo: (T, T) -> Bool {
        return { lhs, rhs in
            self.compare(lhs, rhs) == .equal
        }
    }
}

public struct ComparisonStep<T> {
    let compare: (T, T) -> ComparisonResult
}

@resultBuilder
public struct ComparableBuilder<T> {
    public static func buildBlock(_ components: ComparisonStep<T>...) -> [ComparisonStep<T>] {
        return components
    }

    public static func buildOptional(_ component: [ComparisonStep<T>]?) -> [ComparisonStep<T>] {
        return component ?? []
    }

    public static func buildEither(first component: [ComparisonStep<T>]) -> [ComparisonStep<T>] {
        return component
    }

    public static func buildEither(second component: [ComparisonStep<T>]) -> [ComparisonStep<T>] {
        return component
    }

    public static func buildArray(_ components: [[ComparisonStep<T>]]) -> [ComparisonStep<T>] {
        return components.flatMap { $0 }
    }
}

public protocol ComparableBuildable: Comparable {
    static var comparableDefinition: ComparableDefinition<Self> { get }
}

extension ComparableBuildable {
    public static func compare<V: Comparable>(_ keyPath: KeyPath<Self, V?>) -> ComparisonStep<Self> {
        return ComparisonStep { lhs, rhs in
            guard let lhsValue = lhs[keyPath: keyPath] else {
                if rhs[keyPath: keyPath] == nil {
                    return .equal
                }
                return .ascending
            }

            guard let rhsValue = rhs[keyPath: keyPath] else {
                return .descending
            }

            if lhsValue < rhsValue {
                return .ascending
            } else if lhsValue > rhsValue {
                return .descending
            } else {
                return .equal
            }
        }
    }

    public static func compare<V: Comparable>(_ keyPath: KeyPath<Self, V>) -> ComparisonStep<Self> {
        return ComparisonStep { lhs, rhs in
            let lhsValue = lhs[keyPath: keyPath]
            let rhsValue = rhs[keyPath: keyPath]

            if lhsValue < rhsValue {
                return .ascending
            } else if lhsValue > rhsValue {
                return .descending
            } else {
                return .equal
            }
        }
    }

    public static func makeComparable(@ComparableBuilder<Self> builder: () -> [ComparisonStep<Self>]) -> ComparableDefinition<Self> {
        return ComparableDefinition(steps: builder())
    }

    public static func compareDescending<V: Comparable>(_ keyPath: KeyPath<Self, V>) -> ComparisonStep<Self> {
        return ComparisonStep { lhs, rhs in
            let lhsValue = lhs[keyPath: keyPath]
            let rhsValue = rhs[keyPath: keyPath]

            if lhsValue > rhsValue {
                return .ascending
            } else if lhsValue < rhsValue {
                return .descending
            } else {
                return .equal
            }
        }
    }

    public static func compareCustom<V>(_ keyPath: KeyPath<Self, V>, _ comparator: @escaping (V, V) -> ComparisonResult) -> ComparisonStep<Self> {
        return ComparisonStep { lhs, rhs in
            let lhsValue = lhs[keyPath: keyPath]
            let rhsValue = rhs[keyPath: keyPath]
            return comparator(lhsValue, rhsValue)
        }
    }
}

extension ComparableBuildable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        return comparableDefinition.lessThan(lhs, rhs)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        return comparableDefinition.equalTo(lhs, rhs)
    }
}
