#if os(macOS)

import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

enum RuntimeXPCServiceMessaging {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from payload: Data) throws -> Value {
        try JSONDecoder().decode(type, from: payload)
    }

    /// Runs a handler body and folds its outcome into a reply frame, so the
    /// sending side always gets a frame back and never a transport-level
    /// error it would have to decode.
    static func replying(_ body: () async throws -> Data) async -> RuntimeXPCServiceReplyFrame {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    /// Unwraps a reply frame: a carried failure becomes a thrown
    /// `RuntimeXPCServiceConnectionError.remoteFailure`.
    static func unwrap(_ frame: RuntimeXPCServiceReplyFrame) throws -> Data {
        if let failure = frame.failure {
            throw RuntimeXPCServiceConnectionError.remoteFailure(failure)
        }
        return frame.payload
    }
}

#endif
