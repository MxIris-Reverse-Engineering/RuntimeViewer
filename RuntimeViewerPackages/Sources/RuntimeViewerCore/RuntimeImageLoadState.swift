//
//  File.swift
//  
//
//  Created by JH on 2024/6/3.
//

import Foundation

public enum RuntimeImageLoadState {
    case notLoaded
    case loading
    case loaded
    case loadError(Error)
}
