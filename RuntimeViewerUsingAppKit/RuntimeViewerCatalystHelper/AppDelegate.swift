#if canImport(UIKit)

//
//  AppDelegate.swift
//  RuntimeViewerCatalystHelper
//
//  Created by JH on 2024/6/25.
//

import UIKit
import OSLog

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    private static let logger = Logger(subsystem: "com.RuntimeViewer.RuntimeViewerCatalystHelper", category: "AppDelegate")

    /// The loaded plugin, which keeps the helper's engine; held for the life
    /// of the application.
    private var plugin: ServicePlugin?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        do {
            let plugin = try ServicePluginLoader.loadPlugin()
            self.plugin = plugin
            plugin.launchCatalystHelper()
        } catch {
            Self.logger.error("\(error, privacy: .public)")
        }
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}

#endif
