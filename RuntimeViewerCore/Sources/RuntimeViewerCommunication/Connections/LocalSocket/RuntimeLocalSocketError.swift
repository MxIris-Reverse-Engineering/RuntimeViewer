import Foundation
import FoundationToolbox
import Combine

/// Errors that can occur during local socket communication.
enum RuntimeLocalSocketError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case notConnected
    case receiveFailed
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32, host: String, port: UInt16)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case connectFailed(errno: Int32, host: String, port: UInt16)
    case invalidHostAddress(String)
    case sendFailed(errno: Int32)
    case portFileNotFound(path: String, timeout: TimeInterval)
    case invalidPortFile(path: String, content: String?)

    var description: String {
        switch self {
        case .notConnected:
            return "RuntimeLocalSocketError.notConnected: Socket is not connected"
        case .receiveFailed:
            return "RuntimeLocalSocketError.receiveFailed: Failed to receive data from socket"
        case .socketCreationFailed(let errno):
            return "RuntimeLocalSocketError.socketCreationFailed: Failed to create socket - \(Self.errnoDescription(errno))"
        case .bindFailed(let errno, let host, let port):
            return "RuntimeLocalSocketError.bindFailed: Failed to bind to \(host):\(port) - \(Self.errnoDescription(errno))"
        case .listenFailed(let errno):
            return "RuntimeLocalSocketError.listenFailed: Failed to listen on socket - \(Self.errnoDescription(errno))"
        case .acceptFailed(let errno):
            return "RuntimeLocalSocketError.acceptFailed: Failed to accept connection - \(Self.errnoDescription(errno))"
        case .connectFailed(let errno, let host, let port):
            return "RuntimeLocalSocketError.connectFailed: Failed to connect to \(host):\(port) - \(Self.errnoDescription(errno))"
        case .invalidHostAddress(let host):
            return "RuntimeLocalSocketError.invalidHostAddress: '\(host)' is not an IPv4 address this connection can dial"
        case .sendFailed(let errno):
            return "RuntimeLocalSocketError.sendFailed: Failed to send data - \(Self.errnoDescription(errno))"
        case .portFileNotFound(let path, let timeout):
            return "RuntimeLocalSocketError.portFileNotFound: Port file not found at '\(path)' after \(timeout)s timeout"
        case .invalidPortFile(let path, let content):
            return "RuntimeLocalSocketError.invalidPortFile: Invalid port file at '\(path)', content: '\(content ?? "nil")'"
        }
    }

    var errorDescription: String? { description }

    private static func errnoDescription(_ errno: Int32) -> String {
        let name = errnoName(errno)
        let message = String(cString: strerror(errno))
        return "errno=\(errno) (\(name)): \(message)"
    }

    private static func errnoName(_ errno: Int32) -> String {
        switch errno {
        case EPERM: return "EPERM"
        case ENOENT: return "ENOENT"
        case ESRCH: return "ESRCH"
        case EINTR: return "EINTR"
        case EIO: return "EIO"
        case ENXIO: return "ENXIO"
        case E2BIG: return "E2BIG"
        case ENOEXEC: return "ENOEXEC"
        case EBADF: return "EBADF"
        case ECHILD: return "ECHILD"
        case EDEADLK: return "EDEADLK"
        case ENOMEM: return "ENOMEM"
        case EACCES: return "EACCES"
        case EFAULT: return "EFAULT"
        case EBUSY: return "EBUSY"
        case EEXIST: return "EEXIST"
        case EXDEV: return "EXDEV"
        case ENODEV: return "ENODEV"
        case ENOTDIR: return "ENOTDIR"
        case EISDIR: return "EISDIR"
        case EINVAL: return "EINVAL"
        case ENFILE: return "ENFILE"
        case EMFILE: return "EMFILE"
        case ENOTTY: return "ENOTTY"
        case ETXTBSY: return "ETXTBSY"
        case EFBIG: return "EFBIG"
        case ENOSPC: return "ENOSPC"
        case ESPIPE: return "ESPIPE"
        case EROFS: return "EROFS"
        case EMLINK: return "EMLINK"
        case EPIPE: return "EPIPE"
        case EDOM: return "EDOM"
        case ERANGE: return "ERANGE"
        case EAGAIN: return "EAGAIN"
        case EINPROGRESS: return "EINPROGRESS"
        case EALREADY: return "EALREADY"
        case ENOTSOCK: return "ENOTSOCK"
        case EDESTADDRREQ: return "EDESTADDRREQ"
        case EMSGSIZE: return "EMSGSIZE"
        case EPROTOTYPE: return "EPROTOTYPE"
        case ENOPROTOOPT: return "ENOPROTOOPT"
        case EPROTONOSUPPORT: return "EPROTONOSUPPORT"
        case ENOTSUP: return "ENOTSUP"
        case EAFNOSUPPORT: return "EAFNOSUPPORT"
        case EADDRINUSE: return "EADDRINUSE"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case ENETDOWN: return "ENETDOWN"
        case ENETUNREACH: return "ENETUNREACH"
        case ENETRESET: return "ENETRESET"
        case ECONNABORTED: return "ECONNABORTED"
        case ECONNRESET: return "ECONNRESET"
        case ENOBUFS: return "ENOBUFS"
        case EISCONN: return "EISCONN"
        case ENOTCONN: return "ENOTCONN"
        case ETIMEDOUT: return "ETIMEDOUT"
        case ECONNREFUSED: return "ECONNREFUSED"
        case ELOOP: return "ELOOP"
        case ENAMETOOLONG: return "ENAMETOOLONG"
        case EHOSTDOWN: return "EHOSTDOWN"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENOTEMPTY: return "ENOTEMPTY"
        case ENOLCK: return "ENOLCK"
        case ENOSYS: return "ENOSYS"
        default: return "UNKNOWN"
        }
    }
}
