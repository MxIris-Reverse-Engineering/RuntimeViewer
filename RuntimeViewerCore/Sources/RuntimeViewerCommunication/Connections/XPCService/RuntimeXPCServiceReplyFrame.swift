#if os(macOS)

public import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

/// Every message on an XPC-service connection carries one `Data` payload in,
/// and one of these out. The payloads are JSON — the same encoding every other
/// `RuntimeConnection` uses — so a value that crosses a socket today crosses
/// XPC unchanged, and a handler failure travels as a description instead of
/// relying on SwiftyXPC's error registry, which only round-trips registered
/// error types.
struct RuntimeXPCServiceReplyFrame: Codable, Sendable {
    let payload: Data
    let failure: String?

    static func success(_ payload: Data) -> Self {
        Self(payload: payload, failure: nil)
    }

    static func failure(_ error: any Error) -> Self {
        Self(payload: Data(), failure: error.localizedDescription)
    }
}

#endif
