import UIKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication

@Loggable
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var remoteRuntimeEngine: RuntimeEngine?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #log(.info,"Application did finish launching")
        #log(.info,"Initializing local runtime engine...")
        DispatchQueue.global().async {
            _ = RuntimeEngine.local
            #log(.info,"Local runtime engine initialized")
        }
        Task {
            // The same readable, launch-stable name the injected payload
            // advertises. A device running both still shows up as two entries
            // under one section: the host tells them apart by the TXT record's
            // device ID and pid, not by this name. The user-friendly device
            // name is resolved inside `makeService` and travels in the TXT
            // record — resolving it here as well would just repeat the lookup.
            let serviceName = RuntimeNetworkBonjour.localServiceName
            #log(.info,"Creating Bonjour server runtime engine with service name: \(serviceName, privacy: .private)")
            remoteRuntimeEngine = RuntimeEngine(source: .bonjour(name: serviceName, identifier: .init(rawValue: serviceName), role: .server))
            do {
                try await remoteRuntimeEngine?.connect()
                #log(.info,"Bonjour server runtime engine connected successfully")
            } catch {
                #log(.error,"Failed to connect Bonjour server runtime engine: \(error, privacy: .public)")
            }
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
