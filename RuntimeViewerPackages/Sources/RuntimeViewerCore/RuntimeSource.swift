import Foundation

public enum RuntimeSource: CustomStringConvertible {
    case local
    
    @available(iOS, unavailable)
    @available(tvOS, unavailable)
    @available(watchOS, unavailable)
    @available(visionOS, unavailable)
    case remote(name: String, identifier: Identifier, role: Role)
    
    public var description: String {
        switch self {
        case .local: return "Native"
        case let .remote(name, _, _): return name
        }
    }

    public enum Role {
        case client
        case server
        var isClient: Bool { self == .client }
        var isServer: Bool { self == .server }
    }

    public struct Identifier: RawRepresentable, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: StringLiteralType) {
            self.init(rawValue: value)
        }
    }
}

extension RuntimeSource {
    public static let macCatalystClient: Self = .remote(name: "Mac Catalyst", identifier: .macCatalyst, role: .client)
    public static let macCatalystServer: Self = .remote(name: "Mac Catalyst", identifier: .macCatalyst, role: .server)
}

extension RuntimeSource.Identifier {
    public static let macCatalyst: Self = "com.JH.RuntimeViewer.MacCatalyst"
}
