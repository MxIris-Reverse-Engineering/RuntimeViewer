#if os(macOS)
import AppKit
import SwiftyXPC

public enum CommandSet {
    public static let updateEndpoint = "com.JH.RuntimeViewerService.CommandSet.updateEndpoint"
    public static let fetchEndpoint = "com.JH.RuntimeViewerService.CommandSet.fetchEndpoint"
    public static let launchCatalystHelper = "com.JH.RuntimeViewerService.CommandSet.launchCatalystHelper"
    public static let ping = "com.JH.RuntimeViewerService.CommandSet.ping"
}


public struct RegisterEndpointRequest: Codable {
    public let name: String
    
    public let endpoint: XPCEndpoint
    
    public init(name: String, endpoint: XPCEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

public struct FetchEndpointRequest: Codable {
    
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}

public final class RuntimeViewerService {
    public static let serviceName = "com.JH.RuntimeViewerService"

    private let listener: SwiftyXPC.XPCListener
    
    private var endpoint: XPCEndpoint?

    private var catalystHelperApplication: NSRunningApplication?
    
    private init() throws {
        self.listener = try .init(type: .machService(name: Self.serviceName), codeSigningRequirement: nil)
        listener.setMessageHandler(name: CommandSet.updateEndpoint, handler: updateEndpoint)
        listener.setMessageHandler(name: CommandSet.fetchEndpoint, handler: fetchEndpoint)
        listener.setMessageHandler(name: CommandSet.launchCatalystHelper, handler: launchCatalystHelper)
        listener.setMessageHandler(name: CommandSet.ping, handler: ping(_:))
        listener.activate()
    }
    
    private func ping(_ connection: XPCConnection) async throws -> String {
        return "Ping service successfully"
    }

    private func fetchEndpoint(_ connection: XPCConnection) async throws -> XPCEndpoint {
        guard let endpoint = self.endpoint else {
            throw XPCError.unknown("No endpoint available")
        }
        return endpoint
    }
    
    private func updateEndpoint(_ connection: XPCConnection, endpoint: XPCEndpoint?) async throws {
        self.endpoint = endpoint
    }

    private func launchCatalystHelper(_ connection: XPCConnection, helperURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.activates = false
        catalystHelperApplication = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration)
    }
    
    public static func main() throws {
        try autoreleasepool {
            _ = try RuntimeViewerService()
            RunLoop.current.run()
        }
    }
}
#endif
