import Foundation
import ClassDumpRuntime

public enum RuntimeObjectType: Codable, Hashable, Identifiable, Sendable {
    case `class`(named: String)
    case `protocol`(named: String)

    public var id: Self { self }
}

extension RuntimeObjectType {
    public var name: String {
        switch self {
        case .class(let name):
            return name
        case .protocol(let name):
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
            if let cls = NSClassFromString(named) {
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

extension RuntimeObjectType {
    enum RuntimeError: Error {
        case fetchRuntimeObjectFailed
    }

    func semanticString(for options: CDGenerationOptions) -> CDSemanticString? {
        switch self {
        case .class(let named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                return classModel.semanticLines(with: options)
            } else {
                return nil
            }
        case .protocol(let named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                return protocolModel.semanticLines(with: options)
            } else {
                return nil
            }
        }
    }

    private func requestRuntimeObject<T>(class: (CDClassModel) throws -> T, protocol: (CDProtocolModel) throws -> T) throws -> T {
        switch self {
        case .class(let named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                return try `class`(classModel)
            } else {
                throw RuntimeError.fetchRuntimeObjectFailed
            }
        case .protocol(let named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                return try `protocol`(protocolModel)
            } else {
                throw RuntimeError.fetchRuntimeObjectFailed
            }
        }
    }

    func info() throws -> RuntimeObjectInfo {
        try requestRuntimeObject {
            .class(
                RuntimeClassObjectInfo(
                    numberOfIvars: $0.ivars?.count ?? 0,
                    numberOfInstanceProperties: $0.instanceProperties?.count ?? 0,
                    numberOfInstanceMethods: $0.instanceMethods?.count ?? 0,
                    numberOfClassProperties: $0.classProperties?.count ?? 0,
                    numberOfClassMethods: $0.classMethods?.count ?? 0,
                    numberOfConformProtocols: $0.protocols?.count ?? 0
                )
            )
        } `protocol`: {
            .protocol(
                RuntimeProtocolObjectInfo(
                    numberOfRequiredInstanceProperties: $0.requiredInstanceProperties?.count ?? 0,
                    numberOfRequiredInstanceMethods: $0.requiredInstanceMethods?.count ?? 0,
                    numberOfRequiredClassProperties: $0.requiredClassProperties?.count ?? 0,
                    numberOfRequiredClassMethods: $0.requiredClassMethods?.count ?? 0,
                    numberOfOptionalInstanceProperties: $0.optionalInstanceProperties?.count ?? 0,
                    numberOfOptionalInstanceMethods: $0.optionalInstanceMethods?.count ?? 0,
                    numberOfOptionalClassProperties: $0.optionalClassProperties?.count ?? 0,
                    numberOfOptionalClassMethods: $0.optionalClassMethods?.count ?? 0,
                    numberOfConformProtocols: $0.protocols?.count ?? 0
                )
            )
        }
    }
}

public enum RuntimeObjectInfo: Codable, Sendable {
    case `class`(RuntimeClassObjectInfo)
    case `protocol`(RuntimeProtocolObjectInfo)
}

public struct RuntimeClassObjectInfo: Codable, Sendable {
    public let numberOfIvars: Int
    public let numberOfInstanceProperties: Int
    public let numberOfInstanceMethods: Int
    public let numberOfClassProperties: Int
    public let numberOfClassMethods: Int
    public let numberOfConformProtocols: Int
}

public struct RuntimeProtocolObjectInfo: Codable, Sendable {
    public let numberOfRequiredInstanceProperties: Int
    public let numberOfRequiredInstanceMethods: Int
    public let numberOfRequiredClassProperties: Int
    public let numberOfRequiredClassMethods: Int
    public let numberOfOptionalInstanceProperties: Int
    public let numberOfOptionalInstanceMethods: Int
    public let numberOfOptionalClassProperties: Int
    public let numberOfOptionalClassMethods: Int
    public let numberOfConformProtocols: Int
}
