import Foundation

extension RuntimeSource {
    public enum Role: Sendable, Codable, Equatable {
        case client
        case server
        public var isClient: Bool { self == .client }
        public var isServer: Bool { self == .server }
    }

    public struct Identifier: Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, Equatable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: StringLiteralType) {
            self.init(rawValue: value)
        }
    }
}

public enum RuntimeSource: Sendable, CustomStringConvertible, Codable, Equatable {
    case local
    case remote(name: String, identifier: Identifier, role: Role)
    case bonjourClient(endpoint: RuntimeNetworkEndpoint)
    case bonjourServer(name: String, identifier: Identifier)

    public var description: String {
        switch self {
        case .local: return "My Mac"
        case let .remote(name, _, _): return name
        case let .bonjourClient(endpoint): return endpoint.name
        case let .bonjourServer(name, _): return name
        }
    }

    public var isRemote: Bool {
        switch self {
        case .remote: return true
        case .bonjourClient,
             .bonjourServer: return true
        default: return false
        }
    }

    public var remoteRole: Role? {
        switch self {
        case let .remote(_, _, role): return role
        case .bonjourClient: return .client
        case .bonjourServer: return .server
        default: return nil
        }
    }
}

#if os(macOS)
extension RuntimeSource {
    public static let macCatalystClient: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client)
    public static let macCatalystServer: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .server)
}

extension RuntimeSource.Identifier {
    public static let macCatalyst: Self = "com.RuntimeViewer.RuntimeSource.MacCatalyst"
}
#endif
