import UIKit
import Dependencies
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerEngineManagement

@Loggable
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The engines this device offers: `.local`, and the Bonjour server a Mac
    /// connects to. Reading it is what brings them up, so it is read only once
    /// the commands below are registered.
    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    @Dependency(\.settingsLifecycleController)
    private var settingsLifecycleController

    @Dependency(\.appearanceController)
    private var appearanceController

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #log(.info,"Application did finish launching")
        // First of all: the settings are read before anything below or the
        // first scene reads one, and written whenever the app leaves the
        // foreground from here on.
        settingsLifecycleController.loadOnLaunch()
        // Then the Appearance setting, followed for every window from here on;
        // each scene applies it to its own window as it creates one.
        appearanceController.start()
        // Before any engine exists: a host can query either of the engines
        // below for injection capability as soon as it can reach them, and the
        // answer comes from this registration.
        InjectionServiceRegistrar.registerIfAvailable()
        // The cross-reference commands, before any engine for the same reason:
        // a host asking this device's engines for callers is answered here.
        RuntimeCrossReferences.install()
        // Also before anything else: from here on this process keeps answering
        // after it leaves the foreground, which is what makes an attach from
        // the Mac possible without first bringing the app forward on the
        // device.
        SuspensionPreventionRegistrar.registerIfAvailable()
        #log(.info,"Initializing local runtime engine...")
        DispatchQueue.global().async {
            _ = RuntimeEngine.local
            #log(.info,"Local runtime engine initialized")
        }
        // The manager is configured as a device (`.deviceApplication`): it
        // advertises this device's runtime over Bonjour, under the name the
        // user gave the device, for a Mac to inspect, and lists `.local`. It
        // neither browses nor shares — a Bonjour server takes one client at a
        // time, and a device that connected to a Mac would take that Mac's.
        _ = runtimeEngineManager
        #log(.info,"Runtime engine manager started")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
