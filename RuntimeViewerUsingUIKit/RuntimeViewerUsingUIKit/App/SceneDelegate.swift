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

    private var mainCoordinator: MainCoordinator?

    @Dependency(\.appearanceController)
    private var appearanceController

    @Dependency(\.documentSessionRegistry)
    private var documentSessionRegistry

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        // The window's document: the one it already had when the system
        // connects it again, the file's when it was opened for one, this
        // device's otherwise. It joins the engine's background work before
        // anything binds, as the Mac's document does.
        let requestIdentifier = connectionOptions.userActivities.lazy.compactMap(FileWindowActivity.requestIdentifier(of:)).first
        let documentSession = documentSessionRegistry.session(forWindow: session.persistentIdentifier, requestIdentifier: requestIdentifier)
        documentSession.open()

        let window = UIWindow(windowScene: windowScene)
        // The Appearance setting, before the window first shows.
        appearanceController.apply(to: window)
        let mainCoordinator = MainCoordinator(documentState: documentSession.documentState)
        window.rootViewController = mainCoordinator.rootViewController
        self.window = window
        self.mainCoordinator = mainCoordinator
        mainCoordinator.trigger(.initial)
        window.makeKeyAndVisible()
    }
}
