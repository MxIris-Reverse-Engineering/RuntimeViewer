//
//  ContentRoute.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/22.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObjectType)
    case next(RuntimeObjectType)
    case back
}
