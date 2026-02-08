//
//  SceneDelegate.swift
//  RuntimeViewerUsingUIKit
//
//  Created by JH on 2024/6/3.
//

import UIKit
import RuntimeViewerApplication

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UISplitViewControllerDelegate {
    var window: UIWindow?

    let appState = AppState()

    lazy var mainCoordinator = MainCoordinator(appState: appState)

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = mainCoordinator.rootViewController
        self.window = window
        mainCoordinator.trigger(.initial)
        window.makeKeyAndVisible()
    }
}
