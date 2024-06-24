//
//  AppKitPluginImpl.swift
//  AppKitPlugin
//
//  Created by JH on 2024/6/24.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerApplication

@objc(AppKitPluginImpl)
class AppKitPluginImpl: NSObject, AppKitPlugin {
    let appServices = AppServices()

    lazy var mainCoordinator = MainCoordinator(appServices: appServices)
    
    override required init() {
        super.init()
    }
    
    func launch() {
        _ = mainCoordinator
        DispatchQueue.global().async {
            _ = RuntimeListings.shared
        }
    }
}
