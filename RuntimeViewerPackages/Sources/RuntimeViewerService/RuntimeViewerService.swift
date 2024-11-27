#if os(macOS)
import AppKit
import SwiftyXPC
import RuntimeViewerCommunication

public final class RuntimeViewerService {

    private let listener: SwiftyXPC.XPCListener

    private var catalystHelperApplication: NSRunningApplication?

    private var endpointByIdentifier: [String: XPCEndpoint] = [:]

    private init() throws {
        self.listener = try .init(type: .machService(name: RuntimeViewerMachServiceName), codeSigningRequirement: nil)
        listener.setMessageHandler(handler: registerEndpoint)
        listener.setMessageHandler(handler: fetchEndpoint)
        listener.setMessageHandler(handler: launchCatalystHelper)
        listener.setMessageHandler(handler: ping)
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

    public static func main() throws {
        try autoreleasepool {
            _ = try RuntimeViewerService()
            RunLoop.current.run()
        }
    }
}
#endif
