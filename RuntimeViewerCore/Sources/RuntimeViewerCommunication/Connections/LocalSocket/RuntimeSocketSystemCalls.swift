import Foundation

/// The system calls the local socket connections make on a socket once it is
/// connected or listening, so a test can stand in for them and decide when
/// each one returns and how it fails.
///
/// Each call returns what the system call returns and leaves its error in
/// `errno`, which the caller reads right after the call.
protocol RuntimeSocketSystemCalls: Sendable {
    /// `accept(2)`, without the peer's address.
    func accept(_ socketDescriptor: Int32) -> Int32

    /// `recv(2)` into `buffer`, without flags.
    func receive(_ socketDescriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int

    /// `send(2)` from `buffer`, without flags.
    func send(_ socketDescriptor: Int32, from buffer: UnsafeRawBufferPointer) -> Int

    /// `shutdown(2)` in both directions.
    func shutdown(_ socketDescriptor: Int32)

    /// `close(2)`.
    func close(_ socketDescriptor: Int32)
}
