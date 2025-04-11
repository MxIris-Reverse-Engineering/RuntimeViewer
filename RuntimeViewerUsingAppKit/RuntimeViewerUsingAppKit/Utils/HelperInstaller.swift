#if os(macOS)
import Foundation
import ServiceManagement
import RuntimeViewerCommunication
import SwiftyXPC
import OSLog

public final class RuntimeHelperClient {
    public enum Error: LocalizedError {
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    private static let logger = Logger(subsystem: "com.JH.RuntimeViewerCore", category: "RuntimeInjectClient")

    public static let shared = RuntimeHelperClient()

    private var connection: XPCConnection?

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

    public func isInstalled() async -> Bool {
        do {
            let connection = try connectionIfNeeded()
            try await connection.sendMessage(request: PingRequest())
            return true
        } catch {
            return false
        }
    }

    public func install() async throws {
//        guard await !isInstalled() else { throw Error.message("Helper already installed") }
        func executeAuthorizationFunction(_ authorizationFunction: () -> (OSStatus)) throws {
            let osStatus = authorizationFunction()
            guard osStatus == errAuthorizationSuccess else {
                throw Error.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
            }
        }

        func authorizationRef(
            _ rights: UnsafePointer<AuthorizationRights>?,
            _ environment: UnsafePointer<AuthorizationEnvironment>?,
            _ flags: AuthorizationFlags
        ) throws -> AuthorizationRef? {
            var authRef: AuthorizationRef?
            try executeAuthorizationFunction { AuthorizationCreate(rights, environment, flags, &authRef) }
            return authRef
        }
        var cfError: Unmanaged<CFError>?

        var authItem: AuthorizationItem = kSMRightBlessPrivilegedHelper.withCString {
            AuthorizationItem(name: $0, valueLength: 0, value: UnsafeMutableRawPointer(bitPattern: 0), flags: 0)
        }

        var authRights = AuthorizationRights(count: 1, items: withUnsafeMutablePointer(to: &authItem) { $0 })

        let authRef = try authorizationRef(&authRights, nil, [.interactionAllowed, .extendRights, .preAuthorize])
        SMJobBless(kSMDomainSystemLaunchd, RuntimeViewerMachServiceName as CFString, authRef, &cfError)
        if let error = cfError?.takeRetainedValue() {
            throw error
        }
    }
}
#endif
