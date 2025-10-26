import Foundation
import Semantic
import OrderedCollections
import MachOKit
import MachOSwiftSection
import SwiftDump
import SwiftInterface
import Demangling

public final class RuntimeSwiftSection {
    public enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
    }

    public let imagePath: String

    private let machO: MachOImage

    private var interfaceByName: OrderedDictionary<RuntimeObjectName, RuntimeObjectInterface> = [:]

    private let builder: SwiftInterfaceBuilder<MachOImage>

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

    private var nameToInterfaceDefinitionName: [RuntimeObjectName: InterfaceDefinitionName] = [:]

    public init(imagePath: String) throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension
        guard !imageName.starts(with: "libswift") else {
            throw Error.invalidMachOImage
        }
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }
        self.imagePath = imageName
        self.machO = machO
        self.builder = try .init(configuration: .init(showCImportedTypes: false), in: machO)
    }

    func allNames() throws -> [RuntimeObjectName] {
        let rootTypeName = try builder.rootTypeDefinitions.map { try makeRuntimeObjectName(for: $0.value, isChild: false) }
        let rootProtocolName = try builder.rootProtocolDefinitions.map { try makeRuntimeObjectName(for: $0.value, isChild: false) }
        let typeExtensionName = try builder.typeExtensionDefinitions.flatMap { try $0.value.map { try makeRuntimeObjectName(for: $0, definitionName: .typeExtension($0.extensionName)) } }
        let protocolExtensionName = try builder.protocolExtensionDefinitions.flatMap { try $0.value.map { try makeRuntimeObjectName(for: $0, definitionName: .protocolExtension($0.extensionName)) } }
        let typeAliasExtensionName = try builder.typeAliasExtensionDefinitions.flatMap { try $0.value.map { try makeRuntimeObjectName(for: $0, definitionName: .typeAliasExtension($0.extensionName)) } }
        let conformanceExtensionName = try builder.conformanceExtensionDefinitions.flatMap { try $0.value.map { try makeRuntimeObjectName(for: $0, definitionName: .conformance($0.extensionName)) } }
        return rootTypeName + rootProtocolName + typeExtensionName + protocolExtensionName + typeAliasExtensionName + conformanceExtensionName
    }

    private func makeRuntimeObjectName(for extensionDefintion: ExtensionDefinition, definitionName: InterfaceDefinitionName) throws -> RuntimeObjectName {
        let typeChildren = try extensionDefintion.types.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let protocolChildren = try extensionDefintion.protocols.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let mangledName = try mangleAsString(extensionDefintion.extensionName.node)
        let runtimeObjectName = RuntimeObjectName(name: mangledName, kind: extensionDefintion.extensionName.runtimeObjectKind, imagePath: imagePath, children: typeChildren + protocolChildren)
        nameToInterfaceDefinitionName[runtimeObjectName] = definitionName
        return runtimeObjectName
    }

    private func makeRuntimeObjectName(for protocolDefintion: ProtocolDefinition, isChild: Bool) throws -> RuntimeObjectName {
        let mangledName = try mangleAsString(protocolDefintion.protocolName.node)
        let runtimeObjectName = RuntimeObjectName(name: mangledName, kind: protocolDefintion.protocolName.runtimeObjectKind, imagePath: imagePath, children: [])
        if isChild {
            nameToInterfaceDefinitionName[runtimeObjectName] = .childProtocol(protocolDefintion.protocolName)
        } else {
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootProtocol(protocolDefintion.protocolName)
        }
        return runtimeObjectName
    }

    private func makeRuntimeObjectName(for typeDefinition: TypeDefinition, isChild: Bool) throws -> RuntimeObjectName {
        let typeChildren = try typeDefinition.typeChildren.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let protocolChildren = try typeDefinition.protocolChildren.map { try makeRuntimeObjectName(for: $0, isChild: true) }
        let mangledName = try mangleAsString(typeDefinition.typeName.node)
        let runtimeObjectName = RuntimeObjectName(name: mangledName, kind: typeDefinition.typeName.runtimeObjectKind, imagePath: imagePath, children: typeChildren + protocolChildren)
        if isChild {
            nameToInterfaceDefinitionName[runtimeObjectName] = .childType(typeDefinition.typeName)
        } else {
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootType(typeDefinition.typeName)
        }
        return runtimeObjectName
    }

    public func interface(for name: RuntimeObjectName, options: DemangleOptions) throws -> RuntimeObjectInterface {
        if let interface = interfaceByName[name] {
            return interface
        }

        guard let interfaceDefinitionName = nameToInterfaceDefinitionName[name] else { throw Error.invalidRuntimeObjectName }
        var newInterfaceString: SemanticString = ""
        switch interfaceDefinitionName {
        case .rootType(let rootTypeName):
            guard let typeDefinition = builder.rootTypeDefinitions[rootTypeName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try builder.printTypeDefinition(typeDefinition)
        case .childType(let childTypeName):
            guard let typeDefinition = builder.allTypeDefinitions[childTypeName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try builder.printTypeDefinition(typeDefinition)
        case .rootProtocol(let rootProtocolName):
            guard let definition = builder.rootProtocolDefinitions[rootProtocolName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try builder.printProtocolDefinition(definition)
        case .childProtocol(let childProtocolName):
            guard let definition = builder.allProtocolDefinitions[childProtocolName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try builder.printProtocolDefinition(definition)
        case .typeExtension(let typeExtensionName):
            guard let definitions = builder.typeExtensionDefinitions[typeExtensionName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try definitions.map { try builder.printExtensionDefinition($0) }.join(separator: "\n\n")
        case .protocolExtension(let protocolExtensionName):
            guard let definitions = builder.protocolExtensionDefinitions[protocolExtensionName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try definitions.map { try builder.printExtensionDefinition($0) }.join(separator: "\n\n")
        case .typeAliasExtension(let typeAliasExtensionName):
            guard let definitions = builder.typeAliasExtensionDefinitions[typeAliasExtensionName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try definitions.map { try builder.printExtensionDefinition($0) }.join(separator: "\n\n")
        case .conformance(let conformanceExtensionName):
            guard let definitions = builder.conformanceExtensionDefinitions[conformanceExtensionName] else { throw Error.invalidRuntimeObjectName }
            newInterfaceString = try definitions.map { try builder.printExtensionDefinition($0) }.join(separator: "\n\n")
        }
        
        let newInterface = RuntimeObjectInterface(name: name, interfaceString: newInterfaceString)
        interfaceByName[name] = newInterface
        return newInterface
    }
}

extension SwiftInterface.TypeName {
    var runtimeObjectKind: RuntimeObjectKind {
        switch kind {
        case .enum:
            return .swift(.enum)
        case .struct:
            return .swift(.struct)
        case .class:
            return .swift(.class)
        }
    }
}

extension SwiftInterface.ProtocolName {
    var runtimeObjectKind: RuntimeObjectKind {
        return .swift(.protocol)
    }
}

extension SwiftInterface.ExtensionName {
    var runtimeObjectKind: RuntimeObjectKind {
        switch kind {
        case .type(let type):
            switch type {
            case .enum:
                return .swiftExtension(.enum)
            case .struct:
                return .swiftExtension(.struct)
            case .class:
                return .swiftExtension(.class)
            }
        case .protocol:
            return .swiftExtension(.protocol)
        case .typeAlias:
            return .swiftExtension(.typeAlias)
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
