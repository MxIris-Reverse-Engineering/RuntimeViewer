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
    case main(RuntimeListings)
    case select(RuntimeObjectType)
    case inspect(InspectableObject)
    case sidebarBack
    case contentBack
    case generationOptions(sender: NSView)
}
