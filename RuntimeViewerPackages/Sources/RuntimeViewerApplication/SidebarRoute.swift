//
//  SidebarRoute.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/22.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public enum SidebarRoute: Routable {
    case root
    case selectedNode(RuntimeNamedNode)
    case clickedNode(RuntimeNamedNode)
    case selectedObject(RuntimeObjectType)
    case back
}
