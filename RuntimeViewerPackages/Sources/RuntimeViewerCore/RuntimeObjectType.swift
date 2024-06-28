//
//  RuntimeObjectType.swift
//  HeaderViewer
//
//  Created by Leptos on 2/18/24.
//

import Foundation

public enum RuntimeObjectType: Codable, Hashable, Identifiable {
    case `class`(named: String)
    case `protocol`(named: String)

    public var id: Self { self }
}

public extension RuntimeObjectType {
    var name: String {
        switch self {
        case let .class(name):
            return name
        case let .protocol(name):
            return name
        }
    }
}
