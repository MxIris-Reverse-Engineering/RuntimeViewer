import Foundation
import OSLog

public final class RuntimeCommunicator {
    public init() {}

    public func connect(to source: RuntimeSource, modify: ((RuntimeConnection) async throws -> Void)? = nil) async throws -> RuntimeConnection {
        switch source {
        case .local:
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local connection is not supported"])
        case .remote(_, let identifier, let role):
            #if os(macOS)
            if role.isServer {
                return try await RuntimeXPCServerConnection(identifier: identifier, modify: modify)
            } else {
                return try await RuntimeXPCClientConnection(identifier: identifier, modify: modify)
            }
            #else
            throw NSError(domain: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeCommunicator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Remote connection is not supported on this platform"])
            #endif
        case .bonjourClient(let endpoint):
            let runtimeConnection = try RuntimeNetworkClientConnection(endpoint: endpoint)
            try await modify?(runtimeConnection)
            return runtimeConnection
        case .bonjourServer(let name, _):
            let runtimeConnection = try await RuntimeNetworkServerConnection(name: name)
            try await modify?(runtimeConnection)
            return runtimeConnection
        }
    }
}
