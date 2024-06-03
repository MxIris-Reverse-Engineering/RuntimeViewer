//
//  ViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerArchitectures

class ViewModel<Route: Routable>: NSObject {
    let appServices: AppServices
    let router: UnownedRouter<Route>

    init(appServices: AppServices, router: UnownedRouter<Route>) {
        self.appServices = appServices
        self.router = router
    }
}
