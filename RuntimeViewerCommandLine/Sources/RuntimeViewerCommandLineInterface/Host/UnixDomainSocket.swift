import Darwin
import Foundation

/// Thin wrappers over the POSIX calls the host and client need.
enum UnixDomainSocket {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    struct SystemError: Error, CustomStringConvertible, Equatable {
        let operation: String
        let code: Int32

        init(_ operation: String, code: Int32) {
            self.operation = operation
            self.code = code
        }

        var description: String {
            "\(operation) failed: \(String(cString: strerror(code))) (\(code))"
        }

        /// Nothing is listening: the socket file is missing or nobody accepts on it.
        var indicatesAbsentHost: Bool {
            code == ENOENT || code == ECONNREFUSED
        }
    }

    struct PathTooLongError: Error, CustomStringConvertible {
        let path: String

        var description: String {
            "Socket path is longer than \(UnixDomainSocket.maximumPathLength) bytes: \(path). Point RUNTIME_VIEWER_CLI_HOST_DIRECTORY at a shorter directory."
        }
    }

    static func validatePath(_ path: String) throws {
        guard path.utf8.count <= maximumPathLength else {
            throw PathTooLongError(path: path)
        }
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        try validatePath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in buffer.indices {
                buffer[index] = index < bytes.count ? bytes[index] : 0
            }
        }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw SystemError("socket", code: errno)
        }
        configure(fileDescriptor)
        return fileDescriptor
    }

    /// Writes to a peer that went away must fail with `EPIPE`, not kill the process.
    private static func configure(_ fileDescriptor: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
    }

    /// Binds and listens at `path`, replacing whatever file is there. The
    /// caller has established that no live host owns it. The listening
    /// descriptor is non-blocking so `accept` can be driven by a dispatch source.
    static func listen(at path: String, backlog: Int32 = 16) throws -> Int32 {
        var address = try makeAddress(path: path)
        let fileDescriptor = try makeSocket()
        unlink(path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw SystemError("bind", code: code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fileDescriptor, backlog) == 0 else {
            let code = errno
            close(fileDescriptor)
            unlink(path)
            throw SystemError("listen", code: code)
        }
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        return fileDescriptor
    }

    /// Accepts one pending connection; `nil` when none is pending.
    static func accept(on listeningFileDescriptor: Int32) throws -> Int32? {
        let fileDescriptor = Darwin.accept(listeningFileDescriptor, nil, nil)
        guard fileDescriptor >= 0 else {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK {
                return nil
            }
            throw SystemError("accept", code: code)
        }
        configure(fileDescriptor)
        return fileDescriptor
    }

    static func connect(to path: String) throws -> Int32 {
        var address = try makeAddress(path: path)
        let fileDescriptor = try makeSocket()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fileDescriptor)
            throw SystemError("connect", code: code)
        }
        return fileDescriptor
    }

    /// Whether something accepts connections at `path` right now.
    static func isHostListening(at path: String) -> Bool {
        guard let fileDescriptor = try? connect(to: path) else { return false }
        close(fileDescriptor)
        return true
    }

    static func peerUserIdentifier(of fileDescriptor: Int32) -> uid_t? {
        var userIdentifier: uid_t = 0
        var groupIdentifier: gid_t = 0
        guard getpeereid(fileDescriptor, &userIdentifier, &groupIdentifier) == 0 else { return nil }
        return userIdentifier
    }
}

/// An advisory `flock` on a file, held for the lifetime of the value.
final class FileLock: @unchecked Sendable {
    let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Acquires an exclusive lock, or `nil` when another process holds it.
    static func tryAcquire(at url: URL) throws -> FileLock? {
        let fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else {
            throw UnixDomainSocket.SystemError("open \(url.lastPathComponent)", code: errno)
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fileDescriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw UnixDomainSocket.SystemError("flock \(url.lastPathComponent)", code: code)
        }
        return FileLock(fileDescriptor: fileDescriptor)
    }

    /// Acquires an exclusive lock, waiting up to `timeout`.
    static func acquire(at url: URL, timeout: TimeInterval, pollInterval: Duration = .milliseconds(50)) async throws -> FileLock? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let lock = try tryAcquire(at: url) {
                return lock
            }
            guard Date() < deadline else { return nil }
            try await Task.sleep(for: pollInterval)
        }
    }

    func release() {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
