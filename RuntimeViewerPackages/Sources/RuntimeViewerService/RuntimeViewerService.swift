#if os(macOS)
import Foundation
import SwiftyXPC

public enum CommandSet {
    public static let registerReceiverEndpoint = "com.JH.RuntimeViewerService.CommandSet.registerReceiverEndpoint"
    public static let registerSenderEndpoint = "com.JH.RuntimeViewerService.CommandSet.registerSenderEndpoint"
    public static let fetchReceiverEndpoint = "com.JH.RuntimeViewerService.CommandSet.fetchReceiverEndpoint"
    public static let fetchSenderEndpoint = "com.JH.RuntimeViewerService.CommandSet.fetchSenderEndpoint"
    public static let ping = "com.JH.RuntimeViewerService.CommandSet.ping"
}


public final class RuntimeViewerService {
    public static let serviceName = "com.JH.RuntimeViewerService"

    private let listener: SwiftyXPC.XPCListener

    private var receiverEndpoint: XPCEndpoint?
    
    private var senderEndpoint: XPCEndpoint?

    private init() throws {
        self.listener = try .init(type: .machService(name: Self.serviceName), codeSigningRequirement: nil)
        listener.setMessageHandler(name: CommandSet.registerReceiverEndpoint, handler: registerReceiverEndpoint(_:endpoint:))
        listener.setMessageHandler(name: CommandSet.fetchReceiverEndpoint, handler: fetchReceiverEndpoint(_:))
        listener.setMessageHandler(name: CommandSet.registerSenderEndpoint, handler: registerSenderEndpoint(_:endpoint:))
        listener.setMessageHandler(name: CommandSet.fetchSenderEndpoint, handler: fetchSenderEndpoint(_:))
        listener.setMessageHandler(name: CommandSet.ping, handler: ping(_:))
        listener.activate()
    }
    
    private func ping(_ connection: XPCConnection) async throws -> String {
        return "Ping service successfully"
    }

    private func fetchSenderEndpoint(_ connection: XPCConnection) async throws -> XPCEndpoint? {
        return senderEndpoint
    }

    private func registerSenderEndpoint(_ connection: XPCConnection, endpoint: XPCEndpoint?) async throws {
        self.senderEndpoint = endpoint
    }
    
    private func fetchReceiverEndpoint(_ connection: XPCConnection) async throws -> XPCEndpoint? {
        return receiverEndpoint
    }

    private func registerReceiverEndpoint(_ connection: XPCConnection, endpoint: XPCEndpoint?) async throws {
        self.receiverEndpoint = endpoint
    }

    public static func main() throws {
        try autoreleasepool {
            _ = try RuntimeViewerService()
            RunLoop.current.run()
        }
    }
}
#endif
