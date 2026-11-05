import Foundation
import FoundationToolbox
import Combine

/// Handles port discovery using deterministic port calculation.
///
/// Since sandboxed apps cannot share files via `/tmp` or other directories,
/// we use a hash-based algorithm to compute a deterministic port number
/// from the identifier. Both server and client can independently calculate
/// the same port without any file I/O.
@Loggable
enum RuntimeLocalSocketPortDiscovery {

    /// Dynamic/private port range (IANA recommendation)
    private static let portRangeStart: UInt16 = 49152
    private static let portRangeEnd: UInt16 = 65535
    private static let portRangeSize: UInt16 = portRangeEnd - portRangeStart

    /// Computes a deterministic port number from the identifier.
    ///
    /// Uses a simple hash function to map the identifier to a port
    /// in the dynamic/private range (49152-65535).
    ///
    /// - Parameter identifier: Unique identifier for the connection.
    /// - Returns: A port number in the range 49152-65535.
    static func computePort(for identifier: String) -> UInt16 {
        // Use a simple hash: sum of character values with mixing
        var hash: UInt64 = 5381
        for char in identifier.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char) // hash * 33 + char
        }

        let port = UInt16(hash % UInt64(portRangeSize)) + portRangeStart
        #log(.info, "Computed port \(port, privacy: .public) for identifier '\(identifier, privacy: .public)'")
        return port
    }
}
