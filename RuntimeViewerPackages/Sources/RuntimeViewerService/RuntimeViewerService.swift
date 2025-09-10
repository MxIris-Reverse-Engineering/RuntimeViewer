#if os(macOS)
import AppKit
import SwiftyXPC
import RuntimeViewerCommunication
import MachInjector

public final class RuntimeViewerService {
    private let listener: SwiftyXPC.XPCListener

    private var catalystHelperApplication: NSRunningApplication?

    private var endpointByIdentifier: [String: SwiftyXPC.XPCEndpoint] = [:]

    private init() throws {
        self.listener = try .init(type: .machService(name: RuntimeViewerMachServiceName), codeSigningRequirement: nil)
        listener.setMessageHandler(handler: registerEndpoint)
        listener.setMessageHandler(handler: fetchEndpoint)
        listener.setMessageHandler(handler: launchCatalystHelper)
        listener.setMessageHandler(handler: ping)
        listener.setMessageHandler(handler: injectApplication)
        listener.setMessageHandler(handler: fileOperation)
        listener.activate()
    }

    private func ping(_ connection: XPCConnection, request: PingRequest) async throws -> PingRequest.Response {
        return .empty
    }

    private func fetchEndpoint(_ connection: XPCConnection, request: FetchEndpointRequest) async throws -> FetchEndpointRequest.Response {
        guard let endpoint = endpointByIdentifier[request.identifier] else {
            throw XPCError.unknown("No endpoint available")
        }
        return .init(endpoint: endpoint)
    }

    private func registerEndpoint(_ connection: XPCConnection, request: RegisterEndpointRequest) async throws -> RegisterEndpointRequest.Response {
        endpointByIdentifier[request.identifier] = request.endpoint
        return .empty
    }

    private func launchCatalystHelper(_ connection: XPCConnection, request: LaunchCatalystHelperRequest) async throws -> LaunchCatalystHelperRequest.Response {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.activates = false
        catalystHelperApplication = try await NSWorkspace.shared.openApplication(at: request.helperURL, configuration: configuration)
        return .empty
    }

    private func fileOperation(_ connection: XPCConnection, request: FileOperationRequest) async throws -> FileOperationRequest.Response {
        let fileManager = FileManager.default
        switch request.operation {
        case let .createDirectory(url, isIntermediateDirectories):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: isIntermediateDirectories)
        case let .remove(url: url):
            try fileManager.removeItem(at: url)
        case let .move(from: from, to: to):
            try fileManager.moveItem(at: from, to: to)
        case let .copy(from: from, to: to):
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            try fileManager.copyItem(at: from, to: to)
        case let .write(url: url, data: data):
            try data.write(to: url)
        }
        return .empty
    }

    private func injectApplication(_ connection: XPCConnection, request: InjectApplicationRequest) async throws -> InjectApplicationRequest.Response {
        try await MainActor.run {
            try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
        }
        return .empty
    }

    public static func main() throws {
        try autoreleasepool {
            _ = try RuntimeViewerService()
            RunLoop.current.run()
        }
    }
}
#endif
