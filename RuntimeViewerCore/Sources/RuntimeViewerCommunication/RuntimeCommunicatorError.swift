public import Foundation
import FoundationToolbox

#if os(macOS)
import HelperCommunication
#endif

public enum RuntimeCommunicatorError: Error, LocalizedError, Sendable {
    case localConnectionNotSupported
    case remoteConnectionNotSupportedOnThisPlatform
    case bonjourClientRequiresEndpoint
    case directTCPClientRequiresHost
    case directTCPNotSupportedOnThisPlatform

    public var errorDescription: String? {
        switch self {
        case .localConnectionNotSupported:
            return "Local connection is not supported"
        case .remoteConnectionNotSupportedOnThisPlatform:
            return "Remote connection is not supported on this platform"
        case .bonjourClientRequiresEndpoint:
            return "Bonjour client connection requires an endpoint"
        case .directTCPClientRequiresHost:
            return "Direct TCP client connection requires a host"
        case .directTCPNotSupportedOnThisPlatform:
            return "Direct TCP connection is not supported on this platform"
        }
    }
}
