//
//  RuntimeCommunicator.swift
//  RuntimeViewerPackages
//
//  Created by JH on 2025/3/22.
//

import Foundation
import OSLog

public final class RuntimeCommunicator {
    public init() {}

    public func connect(to source: RuntimeSource, modify: ((RuntimeConnection) async throws -> Void)? = nil) async throws -> RuntimeConnection {
        switch source {
        case .local:
            throw NSError(domain: "com.JH.RuntimeViewerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local connection is not supported"])
        case let .remote(_, identifier, role):
            #if os(macOS)
            if role.isServer {
                return try await RuntimeXPCServerConnection(identifier: identifier, modify: modify)
            } else {
                return try await RuntimeXPCClientConnection(identifier: identifier, modify: modify)
            }
            #else
            throw NSError(domain: "com.JH.RuntimeViewerService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Remote connection is not supported on this platform"])
            #endif
        case let .bonjourClient(endpoint):
            let runtimeConnection = try RuntimeNetworkClientConnection(endpoint: endpoint)
            try await modify?(runtimeConnection)
            return runtimeConnection
        case let .bonjourServer(name, _):
            return try await RuntimeNetworkServerConnection(name: name)
        }
    }
}
