//
//  MainRoute.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/22.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

public enum MainRoute: Routable {
    case initial
    case select(RuntimeObjectType)
    case inspect(InspectableType)
    case sidebarBack
}
