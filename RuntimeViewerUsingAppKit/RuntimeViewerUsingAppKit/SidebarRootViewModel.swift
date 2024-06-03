//
//  SidebarRootViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures



class SidebarRootViewModel: ViewModel<SidebarRoute> {
    let rootNode = CDUtilities.dyldSharedCacheImageRootNode
}
