import UIKit
import os.log
import RuntimeViewerCore
import RuntimeViewerCommunication

private let logger = Logger(subsystem: "com.RuntimeViewer", category: "AppDelegate")

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var remoteRuntimeEngine: RuntimeEngine?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        logger.info("Application did finish launching")
        logger.info("Initializing local runtime engine...")
        DispatchQueue.global().async {
            _ = RuntimeEngine.local
            logger.info("Local runtime engine initialized")
        }
        Task {
            let deviceName = UIDevice.current.name
            logger.info("Creating Bonjour server runtime engine with name: \(deviceName, privacy: .public)")
            remoteRuntimeEngine = RuntimeEngine(source: .bonjourServer(name: deviceName, identifier: .init(rawValue: deviceName)))
            do {
                try await remoteRuntimeEngine?.connect()
                logger.info("Bonjour server runtime engine connected successfully")
            } catch {
                logger.error("Failed to connect Bonjour server runtime engine: \(error, privacy: .public)")
            }
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
