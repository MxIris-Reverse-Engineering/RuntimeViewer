#if os(macOS)

import Foundation
import FoundationToolbox
import HelperCommunication
import HelperService
import MachInjector
import RuntimeViewerCommunication

/// Handles `InjectApplicationRequest` by invoking `MachInjector.inject(pid:dylibPath:)`
/// on the main actor (MachInjector requires `task_for_pid` which needs a main-thread
/// host port).
@Loggable
public actor InjectionService: HelperService {
    public enum Error: Swift.Error {
        case deallocated
    }

    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: InjectApplicationRequest) -> InjectApplicationRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.inject(request: request)
        }
    }

    public func run() async throws {}

    private func inject(request: InjectApplicationRequest) async throws -> InjectApplicationRequest.Response {
        try await MainActor.run {
            try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
        }
        return .empty
    }
}

#endif
