public import Foundation
#if canImport(Network)
import Network
#endif
#if os(macOS)
import SwiftyXPC
import HelperPeer
#endif

extension RuntimeConnectionError {
    /// Whether `error`, thrown by a request, says the connection the request
    /// went out on was lost before an answer came — the serving process
    /// exited, the peer closed its end, the connection was stopped — rather
    /// than the peer answering with a failure of its own.
    ///
    /// Each transport words a lost connection its own way, several of them
    /// with types internal to this module, so a caller that has to tell the
    /// two apart — a corpus build interrupted is not a corpus build failed —
    /// asks here. A request that timed out is not one: the peer may still be
    /// there and answer it. Neither is a cancellation, which the caller asked
    /// for.
    public static func isLostConnection(_ error: any Swift.Error) -> Bool {
        if let connectionError = error as? RuntimeConnectionError {
            switch connectionError {
            case .socketError, .networkError, .xpcError, .timeout, .peerClosed, .notConnected:
                return true
            case .listenerWaiting, .unknown:
                return false
            }
        }
        if let channelError = error as? RuntimeMessageChannelError {
            // `receiveFailed` is an answer that could not be read, and
            // `requestTimeout` a peer that may answer yet.
            return channelError == .notConnected
        }
        if let networkError = error as? RuntimeNetworkError {
            switch networkError {
            case .notConnected, .receiveFailed:
                return true
            case .invalidPort:
                return false
            }
        }
        if let localSocketError = error as? RuntimeLocalSocketError {
            switch localSocketError {
            case .notConnected, .receiveFailed, .sendFailed:
                return true
            case .socketCreationFailed, .bindFailed, .listenFailed, .acceptFailed, .connectFailed, .invalidHostAddress, .portFileNotFound, .invalidPortFile:
                return false
            }
        }
        if let stdioError = error as? RuntimeStdioError {
            switch stdioError {
            case .notConnected, .receiveFailed:
                return true
            }
        }
        #if canImport(Network)
        // The transport's own failure on an established connection, handed to
        // every request still waiting on it.
        if error is NWError {
            return true
        }
        #endif
        #if os(macOS)
        if let serviceError = error as? RuntimeXPCServiceConnectionError {
            switch serviceError {
            case .serviceExited, .connectionInvalid, .noClientAttached:
                return true
            case .remoteFailure:
                return false
            }
        }
        // What a Mach service connection — the Catalyst helper, an injected
        // app — throws, straight from SwiftyXPC and the brokered peer.
        if let xpcError = error as? XPCError {
            switch xpcError {
            case .connectionInterrupted, .connectionInvalid, .terminationImminent:
                return true
            default:
                return false
            }
        }
        if let peerClientError = error as? HelperPeerClient.Error {
            switch peerClientError {
            case .peerNotConnected, .cancelled:
                return true
            default:
                return false
            }
        }
        if let peerServerError = error as? HelperPeerServer.Error {
            switch peerServerError {
            case .peerNotConnected, .cancelled:
                return true
            default:
                return false
            }
        }
        #endif
        return false
    }
}
