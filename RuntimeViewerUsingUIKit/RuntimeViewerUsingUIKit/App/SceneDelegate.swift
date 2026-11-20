//
//  SceneDelegate.swift
//  RuntimeViewerUsingUIKit
//
//  Created by JH on 2024/6/3.
//

import UIKit
import Dependencies
import RuntimeViewerApplication

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UISplitViewControllerDelegate {
    var window: UIWindow?

    let documentState = DocumentState()

    lazy var mainCoordinator = MainCoordinator(documentState: documentState)

    @Dependency(\.appearanceController)
    private var appearanceController

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        // The Appearance setting, before the window first shows.
        appearanceController.apply(to: window)
        window.rootViewController = mainCoordinator.rootViewController
        self.window = window
        mainCoordinator.trigger(.initial)
        window.makeKeyAndVisible()
    }
}
