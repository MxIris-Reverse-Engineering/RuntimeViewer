import MachOKit
import FoundationToolbox
import RuntimeViewerObjC
import Foundation
import Combine
import RuntimeViewerCommunication
import Demangling
import OrderedCollections

extension RuntimeConnection {
    func sendMessage(name: RuntimeEngine.CommandName) async throws {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Request: Codable>(name: RuntimeEngine.CommandName, request: Request) async throws {
        return try await sendMessage(name: name.commandName, request: request)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandName) async throws -> Response {
        return try await sendMessage(name: name.commandName)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandName, timeout: TimeInterval?) async throws -> Response {
        return try await sendMessage(name: name.commandName, timeout: timeout)
    }

    func sendMessage<Response: Codable>(name: RuntimeEngine.CommandName, request: some Codable) async throws -> Response {
        return try await sendMessage(name: name.commandName, request: request)
    }
}
