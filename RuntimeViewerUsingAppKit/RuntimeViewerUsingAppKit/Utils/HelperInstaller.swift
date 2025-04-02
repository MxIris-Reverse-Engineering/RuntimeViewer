#if os(macOS)
import Foundation
import ServiceManagement
import RuntimeViewerCommunication

public enum HelperAuthorizationError: Error {
    case message(String)
}

public enum HelperInstaller {
//    private static let daemonService = SMAppService.daemon(plistName: "com.JH.RuntimeViewerService.plist")

    public static func install() throws {
//        try daemonService.register()
//        print(daemonService.status.rawValue)
//        return
        func executeAuthorizationFunction(_ authorizationFunction: () -> (OSStatus)) throws {
            let osStatus = authorizationFunction()
            guard osStatus == errAuthorizationSuccess else {
                throw HelperAuthorizationError.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
            }
        }

        func authorizationRef(_ rights: UnsafePointer<AuthorizationRights>?,
                              _ environment: UnsafePointer<AuthorizationEnvironment>?,
                              _ flags: AuthorizationFlags) throws -> AuthorizationRef? {
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
