//
//  RuntimeObjectType.swift
//  HeaderViewer
//
//  Created by Leptos on 2/18/24.
//

import Foundation
import ClassDumpRuntime

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


private func getClassHierarchy(_ cls: AnyClass) -> [AnyClass] {
    var hierarcy = [AnyClass]()
    hierarcy.append(cls)
    var superclass: AnyClass? = class_getSuperclass(cls)
    while let currentSuperclass = superclass {
        hierarcy.append(currentSuperclass)
        superclass = class_getSuperclass(currentSuperclass)
    }
    
    return hierarcy
}

extension RuntimeObjectType {
    func hierarchy() -> [String] {
        switch self {
        case .class(let named):
            if let cls = NSClassFromString(name) {
                return getClassHierarchy(cls).map { NSStringFromClass($0) }
            } else {
                return []
            }
        case .protocol(let named):
            if let proto = NSProtocolFromString(named) {
                return (CDProtocolModel(with: proto).protocols ?? []).map { $0.name }
            } else {
                return []
            }
        }
    }
}
