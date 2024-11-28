//
//  RuntimeInjectClient.swift
//  RuntimeViewerPackages
//
//  Created by JH on 11/29/24.
//

#if os(macOS)

import OSLog
import SwiftyXPC
import Foundation
import RuntimeViewerCommunication

public final class RuntimeInjectClient {
    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeInjectClient")

    public static let shared = RuntimeInjectClient()

    private var connection: XPCConnection?

    private init() {}

    public func injectApplication(pid: pid_t, dylibURL: URL) async throws {
        try await connectionIfNeeded().sendMessage(request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL))
    }

    private func connectionIfNeeded() throws -> XPCConnection {
        let connection: XPCConnection
        if let currentConnection = self.connection {
            connection = currentConnection
        } else {
            connection = try XPCConnection(type: .remoteMachService(serviceName: RuntimeViewerMachServiceName, isPrivilegedHelperTool: true))
            connection.activate()
            self.connection = connection
        }
        return connection
    }
}

#endif
