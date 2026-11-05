import Foundation
import FoundationToolbox
import Semaphore

/// Protocol defining the message framing and processing logic.
///
/// Implementations handle the low-level details of reading/writing data,
/// while the protocol provides the common message framing logic.
protocol RuntimeMessageProtocol: Sendable {
    /// The end marker used to delimit messages.
    static var endMarkerData: Data { get }
}

extension RuntimeMessageProtocol {
    /// Default end marker: `\nOK`
    static var endMarkerData: Data {
        "\nOK".data(using: .utf8)!
    }
}
