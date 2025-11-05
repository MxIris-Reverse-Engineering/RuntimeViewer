import Foundation
import Semantic
import OrderedCollections
import MachOKit
import MachOSwiftSection
import SwiftDump
import SwiftInterface
import Demangling
import SwiftStdlibToolbox

final class RuntimeSwiftSection: Sendable {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
    }

    let imagePath: String

    private let machO: MachOImage

    private let builder: SwiftInterfaceBuilder<MachOImage>

    @Mutex
    private var interfaceByName: OrderedDictionary<RuntimeObjectName, RuntimeObjectInterface> = [:]

    @Mutex
    private var nameToInterfaceDefinitionName: [RuntimeObjectName: InterfaceDefinitionName] = [:]

    private enum InterfaceDefinitionName {
        case rootType(SwiftInterface.TypeName)
        case childType(SwiftInterface.TypeName)
        case rootProtocol(SwiftInterface.ProtocolName)
        case childProtocol(SwiftInterface.ProtocolName)
        case typeExtension(SwiftInterface.ExtensionName)
        case protocolExtension(SwiftInterface.ExtensionName)
        case typeAliasExtension(SwiftInterface.ExtensionName)
        case conformance(SwiftInterface.ExtensionName)
    }

    init(imagePath: String) async throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
//        guard !imageName.starts(with: "libswift") else {
//            throw Error.invalidMachOImage
//        }
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }
        self.imagePath = imagePath
        self.machO = machO
        self.builder = try .init(configuration: .init(showCImportedTypes: false), in: machO)
        try await builder.prepare()
    }

    func allNames() throws -> [RuntimeObjectName] {
        let rootTypeName = try builder.rootTypeDefinitions.map { try makeRuntimeObjectName(for: $0.value, isChild: false) }
        let rootProtocolName = try builder.rootProtocolDefinitions.map { try makeRuntimeObjectName(for: $0.value, isChild: false) }
        let typeExtensionName = try builder.typeExtensionDefinitions.filter { $0.key.typeName.map { builder.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObjectName(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeExtension($0.key)) }
        let protocolExtensionName = try builder.protocolExtensionDefinitions.filter { $0.key.protocolName.map { builder.allProtocolDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObjectName(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .protocolExtension($0.key)) }
        let typeAliasExtensionName = try builder.typeAliasExtensionDefinitions.map { try makeRuntimeObjectName(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeAliasExtension($0.key)) }
        let conformanceExtensionName = try builder.conformanceExtensionDefinitions.filter { $0.key.typeName.map { builder.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObjectName(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftConformance, definitionName: .conformance($0.key)) }
        return rootTypeName + rootProtocolName + typeExtensionName + protocolExtensionName + typeAliasExtensionName + conformanceExtensionName
    }

    private func makeRuntimeObjectName(for extensionDefintions: [ExtensionDefinition], extensionName: ExtensionName, kind: RuntimeObjectKind, definitionName: InterfaceDefinitionName) throws -> RuntimeObjectName {
        let typeChildren = try extensionDefintions.flatMap { $0.types }.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let protocolChildren = try extensionDefintions.flatMap { $0.protocols }.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let mangledName = try mangleAsString(extensionName.node)
        let runtimeObjectName = RuntimeObjectName(name: mangledName, displayName: extensionName.name, kind: kind, imagePath: imagePath, children: typeChildren + protocolChildren)
        nameToInterfaceDefinitionName[runtimeObjectName] = definitionName
        return runtimeObjectName
    }

    private func makeRuntimeObjectName(for protocolDefintion: ProtocolDefinition, isChild: Bool) throws -> RuntimeObjectName {
        let mangledName = try mangleAsString(protocolDefintion.protocolName.node)
        let runtimeObjectName: RuntimeObjectName
        if isChild {
            runtimeObjectName = RuntimeObjectName(name: mangledName, displayName: protocolDefintion.protocolName.currentName, kind: protocolDefintion.protocolName.runtimeObjectKind, imagePath: imagePath, children: [])
            nameToInterfaceDefinitionName[runtimeObjectName] = .childProtocol(protocolDefintion.protocolName)
        } else {
            runtimeObjectName = RuntimeObjectName(name: mangledName, displayName: protocolDefintion.protocolName.name, kind: protocolDefintion.protocolName.runtimeObjectKind, imagePath: imagePath, children: [])
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootProtocol(protocolDefintion.protocolName)
        }
        return runtimeObjectName
    }

    private func makeRuntimeObjectName(for typeDefinition: TypeDefinition, isChild: Bool) throws -> RuntimeObjectName {
        let typeChildren = try typeDefinition.typeChildren.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let protocolChildren = try typeDefinition.protocolChildren.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let mangledName = try mangleAsString(typeDefinition.typeName.node)
        let runtimeObjectName: RuntimeObjectName
        if isChild {
            runtimeObjectName = RuntimeObjectName(name: mangledName, displayName: typeDefinition.typeName.currentName, kind: typeDefinition.typeName.runtimeObjectKind, imagePath: imagePath, children: typeChildren + protocolChildren)
            nameToInterfaceDefinitionName[runtimeObjectName] = .childType(typeDefinition.typeName)
        } else {
            runtimeObjectName = RuntimeObjectName(name: mangledName, displayName: typeDefinition.typeName.name, kind: typeDefinition.typeName.runtimeObjectKind, imagePath: imagePath, children: typeChildren + protocolChildren)
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootType(typeDefinition.typeName)
        }
        return runtimeObjectName
    }

    func interface(for name: RuntimeObjectName, options: DemangleOptions) async throws -> RuntimeObjectInterface {
        if let interface = interfaceByName[name] {
            return interface
        }

        guard let interfaceDefinitionName = nameToInterfaceDefinitionName[name] else { throw Error.invalidRuntimeObjectName }
        var newInterfaceString: SemanticString = ""
        switch interfaceDefinitionName {
        case .rootType(let rootTypeName):
            guard let typeDefinition = builder.rootTypeDefinitions[rootTypeName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(builder.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = builder.typeExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = builder.conformanceExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childType(let childTypeName):
            guard let typeDefinition = builder.allTypeDefinitions[childTypeName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(builder.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = builder.typeExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = builder.conformanceExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .rootProtocol(let rootProtocolName):
            guard let definition = builder.rootProtocolDefinitions[rootProtocolName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(builder.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = builder.protocolExtensionDefinitions[rootProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childProtocol(let childProtocolName):
            guard let definition = builder.allProtocolDefinitions[childProtocolName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(builder.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = builder.protocolExtensionDefinitions[childProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .typeExtension(let typeExtensionName):
            guard let definitions = builder.typeExtensionDefinitions[typeExtensionName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(definitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .protocolExtension(let protocolExtensionName):
            guard let definitions = builder.protocolExtensionDefinitions[protocolExtensionName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(definitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .typeAliasExtension(let typeAliasExtensionName):
            guard let definitions = builder.typeAliasExtensionDefinitions[typeAliasExtensionName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(definitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .conformance(let conformanceExtensionName):
            guard let definitions = builder.conformanceExtensionDefinitions[conformanceExtensionName] else { throw Error.invalidRuntimeObjectName }
            try await newInterfaceString.append(definitions.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        }

        let newInterface = RuntimeObjectInterface(name: name, interfaceString: newInterfaceString)
        interfaceByName[name] = newInterface
        return newInterface
    }
}

extension SwiftInterface.TypeName {
    fileprivate var runtimeObjectKind: RuntimeObjectKind {
        switch kind {
        case .enum:
            return .swift(.type(.enum))
        case .struct:
            return .swift(.type(.struct))
        case .class:
            return .swift(.type(.class))
        }
    }
}

extension SwiftInterface.ProtocolName {
    fileprivate var runtimeObjectKind: RuntimeObjectKind {
        return .swift(.type(.protocol))
    }
}

extension SwiftInterface.ExtensionName {
    fileprivate var runtimeObjectKindOfSwiftExtension: RuntimeObjectKind {
        switch kind {
        case .type(let type):
            switch type {
            case .enum:
                return .swift(.extension(.enum))
            case .struct:
                return .swift(.extension(.struct))
            case .class:
                return .swift(.extension(.class))
            }
        case .protocol:
            return .swift(.extension(.protocol))
        case .typeAlias:
            return .swift(.extension(.typeAlias))
        }
    }

    fileprivate var runtimeObjectKindOfSwiftConformance: RuntimeObjectKind {
        switch kind {
        case .type(let type):
            switch type {
            case .enum:
                return .swift(.conformance(.enum))
            case .struct:
                return .swift(.conformance(.struct))
            case .class:
                return .swift(.conformance(.class))
            }
        case .protocol:
            return .swift(.conformance(.protocol))
        case .typeAlias:
            return .swift(.conformance(.typeAlias))
        }
    }
}

extension Array where Element == SemanticString {
    func join(separator: SemanticString = "") -> Element {
        var result: SemanticString = ""
        for (index, element) in enumerated() {
            result.append(element)
            if index < count - 1 {
                result.append(separator)
            }
        }
        return result
    }
}

extension ExtensionName {
    fileprivate var typeName: SwiftInterface.TypeName? {
        switch kind {
        case .type(let type):
            switch type {
            case .enum:
                return .init(node: node, kind: .enum)
            case .struct:
                return .init(node: node, kind: .struct)
            case .class:
                return .init(node: node, kind: .class)
            }
        default:
            return nil
        }
    }

    fileprivate var protocolName: SwiftInterface.ProtocolName? {
        switch kind {
        case .protocol:
            return .init(node: node)
        default:
            return nil
        }
    }
}

extension SemanticString {
    fileprivate static var doubleBreakLine: SemanticString {
        "\n\n"
    }
}
