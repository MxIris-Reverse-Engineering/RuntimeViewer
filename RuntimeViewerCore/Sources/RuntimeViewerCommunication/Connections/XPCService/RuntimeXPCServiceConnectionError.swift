#if os(macOS)

public import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

public enum RuntimeXPCServiceConnectionError: Error, LocalizedError, Sendable, Equatable {
    /// The service process exited while this connection was open — a crash,
    /// or launchd tearing it down. The connection itself stays usable: the
    /// next message relaunches the service.
    case serviceExited

    /// The connection can never be used again: it was cancelled, or the
    /// service could not be found in the calling process's bundle.
    case connectionInvalid

    /// The listener side has not been reached by any client yet, so there is
    /// nobody to push to.
    case noClientAttached

    /// The handler on the other side threw. Only its description crosses the
    /// wire; the concrete error type stays in the process that produced it.
    case remoteFailure(String)

    public var errorDescription: String? {
        switch self {
        // Worded for any embedded service: the local runtime and the Mac
        // Catalyst runtime both run in one, and these texts reach the user.
        case .serviceExited:
            return "The runtime service exited while handling this request."
        case .connectionInvalid:
            return "The connection to the runtime service is no longer valid."
        case .noClientAttached:
            return "No client is attached to the runtime service."
        case .remoteFailure(let description):
            return description
        }
    }

    /// Maps SwiftyXPC's transport errors onto this module's vocabulary and
    /// leaves every other error untouched.
    static func mapping(_ error: any Error) -> any Error {
        guard let xpcError = error as? XPCError else { return error }
        switch xpcError {
        case .connectionInterrupted:
            return RuntimeXPCServiceConnectionError.serviceExited
        case .connectionInvalid:
            return RuntimeXPCServiceConnectionError.connectionInvalid
        case .terminationImminent, .invalidCodeSignatureRequirement, .unknown:
            return error
        }
    }
}

#endif
