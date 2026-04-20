import UIKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUtilities
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
            let deviceName = RuntimeNetworkBonjour.localHostName
            let deviceID = DeviceIdentifier.uniqueDeviceID
            #log(.info,"Creating Bonjour server runtime engine with name: \(deviceName, privacy: .public), identifier: \(deviceID, privacy: .private)")
            remoteRuntimeEngine = RuntimeEngine(source: .bonjour(name: deviceName, identifier: .init(rawValue: deviceID), role: .server))
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
