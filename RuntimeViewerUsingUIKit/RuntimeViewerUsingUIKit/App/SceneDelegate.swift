//
//  SceneDelegate.swift
//  RuntimeViewerUsingUIKit
//
//  Created by JH on 2024/6/3.
//

import UIKit
import Dependencies
import RuntimeViewerApplication
import RuntimeViewerEngineManagement

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UISplitViewControllerDelegate {
    var window: UIWindow?

    private var mainCoordinator: MainCoordinator?

    /// The scene this delegate shows, which a file window's close button
    /// asks the system to destroy.
    private weak var windowScene: UIWindowScene?

    @Dependency(\.appearanceController)
    private var appearanceController

    @Dependency(\.documentSessionRegistry)
    private var documentSessionRegistry

    @Dependency(\.runtimeEngineManager)
    private var runtimeEngineManager

    @Dependency(\.fileController)
    private var fileController

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        self.windowScene = windowScene
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
        let isFileWindow = runtimeEngineManager.file(of: documentSession.documentState.runtimeEngine) != nil
        let mainCoordinator = MainCoordinator(documentState: documentSession.documentState, isFileWindow: isFileWindow)
        mainCoordinator.delegate = self
        window.rootViewController = mainCoordinator.rootViewController
        self.window = window
        self.mainCoordinator = mainCoordinator
        mainCoordinator.trigger(.initial)
        window.makeKeyAndVisible()

        // A file another app handed over as it launched this one.
        if !connectionOptions.urlContexts.isEmpty {
            fileController.open(connectionOptions.urlContexts, presentingFrom: mainCoordinator.rootViewController)
        }
    }

    /// A file another app hands over — Open In from Files.
    func scene(_ scene: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
        guard let rootViewController = window?.rootViewController else { return }
        fileController.open(urlContexts, presentingFrom: rootViewController)
    }
}

extension SceneDelegate: MainCoordinatorDelegate {
    /// A file window's close button: the system destroys the scene, and the
    /// window's session closes as the app hears it discarded.
    func mainCoordinatorDidRequestClose(_ mainCoordinator: MainCoordinator) {
        guard let session = windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
    }
}
