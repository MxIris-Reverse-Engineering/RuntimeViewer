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

    public var isInstalledServerFramework: Bool {
        FileManager.default.fileExists(atPath: serverFrameworkDestinationURL.path)
    }

    public let serverFrameworkDestinationURL = URL(fileURLWithPath: "/Library/Frameworks/RuntimeViewerServer.framework")

    public var serverFrameworkSourceURL: URL? {
        Bundle.main.url(forResource: "RuntimeViewerServer", withExtension: "framework")
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

    public func injectApplication(pid: pid_t, dylibURL: URL) async throws {
        try await connectionIfNeeded().sendMessage(request: InjectApplicationRequest(pid: pid, dylibURL: dylibURL))
    }

    public enum Error: LocalizedError {
        case serverFrameworkNotFound
        public var errorDescription: String? {
            switch self {
            case .serverFrameworkNotFound:
                return "Server framework not found."
            }
        }
    }

    public func installServerFrameworkIfNeeded() async throws {
//        guard !isInstalledServerFramework else { return }
        try await installServerFramework()
    }
    
    public func installServerFramework() async throws {
        guard let serverFrameworkSourceURL else {
            throw Error.serverFrameworkNotFound
        }
        try await connectionIfNeeded().sendMessage(request: FileOperationRequest(operation: .copy(from: serverFrameworkSourceURL, to: serverFrameworkDestinationURL)))
    }
}

#endif
