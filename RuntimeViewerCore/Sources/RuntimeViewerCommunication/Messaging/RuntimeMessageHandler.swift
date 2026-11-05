import Foundation
import FoundationToolbox
import Semaphore

/// Encapsulates a message handler that processes requests and returns responses.
///
/// This class handles the JSON encoding/decoding of requests and responses,
/// allowing handlers to work with typed Swift objects.
///
/// - Note: Uses `@unchecked Sendable` because the stored metatypes (`requestType`, `responseType`)
///   are immutable and inherently thread-safe, but `any Codable.Type` doesn't conform to `Sendable`.
final class RuntimeMessageHandler: @unchecked Sendable {
    typealias RawHandler = @Sendable (Data) async throws -> Data

    /// The wrapped handler that processes raw Data.
    let closure: RawHandler

    /// The type of the request this handler expects.
    let requestType: any Codable.Type

    /// The type of the response this handler returns.
    let responseType: any Codable.Type

    /// Creates a message handler with typed request and response.
    ///
    /// - Parameter closure: The handler closure that receives a typed request
    ///   and returns a typed response.
    init<Request: Codable, Response: Codable>(closure: @escaping @Sendable (Request) async throws -> Response) {
        self.requestType = Request.self
        self.responseType = Response.self

        self.closure = { request in
            let request = try JSONDecoder().decode(Request.self, from: request)
            let response = try await closure(request)
            return try JSONEncoder().encode(response)
        }
    }
}
