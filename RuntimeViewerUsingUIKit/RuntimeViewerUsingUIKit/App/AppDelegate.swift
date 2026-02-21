import UIKit
import RuntimeViewerCore
import RuntimeViewerCommunication

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var remoteRuntimeEngine: RuntimeEngine?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DispatchQueue.global().async {
            _ = RuntimeEngine.local
        }
        Task {
            remoteRuntimeEngine = try await RuntimeEngine(source: .bonjourServer(name: UIDevice.current.name, identifier: .init(rawValue: UIDevice.current.name)))
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
