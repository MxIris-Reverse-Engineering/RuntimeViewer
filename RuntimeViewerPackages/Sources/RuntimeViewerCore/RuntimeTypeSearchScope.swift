import Foundation

public enum RuntimeTypeSearchScope: Hashable {
    case all
    case classes
    case protocols
}

public extension RuntimeTypeSearchScope {
    var includesClasses: Bool {
        switch self {
        case .all: true
        case .classes: true
        case .protocols: false
        }
    }

    var includesProtocols: Bool {
        switch self {
        case .all: true
        case .classes: false
        case .protocols: true
        }
    }
}
