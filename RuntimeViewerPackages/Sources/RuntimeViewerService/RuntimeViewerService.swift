import Foundation
import SwiftyXPC

public enum CommandSet {
    public static let registerEndpoint = "com.JH.RuntimeViewerService.CommandSet.registerEndpoint"
    public static let fetchEndpoint = "com.JH.RuntimeViewerService.CommandSet.fetchEndpoint"
    public static let ping = "com.JH.RuntimeViewerService.CommandSet.ping"
}


public final class RuntimeViewerService {
    public static let serviceName = "com.JH.RuntimeViewerService"

    private let listener: SwiftyXPC.XPCListener

    private var endpoint: XPCEndpoint?

    private init() throws {
        self.listener = try .init(type: .machService(name: Self.serviceName), codeSigningRequirement: nil)
        listener.setMessageHandler(name: CommandSet.registerEndpoint, handler: registerEndpoint(_:endpoint:))
        listener.setMessageHandler(name: CommandSet.fetchEndpoint, handler: fetchEndpoint(_:))
        listener.setMessageHandler(name: CommandSet.ping, handler: ping(_:))
        listener.activate()
    }
    
    private func ping(_ connection: XPCConnection) async throws -> String {
        return "Ping successfully"
    }

    private func fetchEndpoint(_ connection: XPCConnection) async throws -> XPCEndpoint? {
        return endpoint
    }

    private func registerEndpoint(_ connection: XPCConnection, endpoint: XPCEndpoint?) async throws {
        self.endpoint = endpoint
    }

    public static func main() throws {
        let service = try RuntimeViewerService()
        RunLoop.current.run()
    }
}
