import Demangling
import Foundation
import FoundationToolbox
import FrameworkToolbox
import MachOKit
import MachOSwiftSection
import OrderedCollections
import OSLog
import Semantic
import SwiftDump
import SwiftInspection
@_spi(Support) import SwiftInterface

public struct SwiftGenerationOptions: Sendable, Codable, Equatable {
    public var printStrippedSymbolicItem: Bool = true
    public var emitOffsetComments: Bool = false
    public var printTypeLayout: Bool = false
    public var printEnumLayout: Bool = false
}

actor RuntimeSwiftSection: Loggable {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private let builder: SwiftInterfaceBuilder<MachOImage>

    private var interfaceByName: OrderedDictionary<RuntimeObject, RuntimeObjectInterface> = [:]

    private var nameToInterfaceDefinitionName: [RuntimeObject: InterfaceDefinitionName] = [:]

    private enum InterfaceDefinitionName {
        case rootType(SwiftInterface.TypeName)
        case childType(SwiftInterface.TypeName)
        case rootProtocol(SwiftInterface.ProtocolName)
        case childProtocol(SwiftInterface.ProtocolName)
        case typeExtension(SwiftInterface.ExtensionName)
        case protocolExtension(SwiftInterface.ExtensionName)
        case typeAliasExtension(SwiftInterface.ExtensionName)
        case conformance(SwiftInterface.ExtensionName)

        var typeName: SwiftInterface.TypeName? {
            switch self {
            case .rootType(let typeName):
                return typeName
            case .childType(let typeName):
                return typeName
            default:
                return nil
            }
        }
    }

    init(imagePath: String) async throws {
        Self.logger.info("Initializing Swift section for image: \(imagePath, privacy: .public)")
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else {
            Self.logger.error("Failed to create MachOImage for: \(imageName, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.imagePath = imagePath
        self.machO = machO
        Self.logger.debug("Creating SwiftInterfaceBuilder")
        self.builder = try .init(configuration: .init(indexConfiguration: .init(showCImportedTypes: false), printConfiguration: .init()), in: machO)
        try await builder.prepare()
        Self.logger.info("Swift section initialized successfully")
    }

    func updateConfiguration(using options: SwiftGenerationOptions) async throws {
        logger.debug("Updating Swift section configuration")
        var configuration = builder.configuration
        configuration.printConfiguration.printStrippedSymbolicItem = options.printStrippedSymbolicItem
        configuration.printConfiguration.emitOffsetComments = options.emitOffsetComments
        configuration.printConfiguration.printTypeLayout = options.printTypeLayout
        configuration.printConfiguration.printEnumLayout = options.printEnumLayout
        try await updateConfiguration(configuration)
    }

    private func updateConfiguration(_ newConfiguration: SwiftInterfaceBuilderConfiguration) async throws {
        let oldConfiguration = builder.configuration
        builder.configuration = newConfiguration

        if newConfiguration.indexConfiguration.showCImportedTypes != oldConfiguration.indexConfiguration.showCImportedTypes {
            logger.debug("Index configuration changed, re-preparing builder")
            try await builder.prepare()
            nameToInterfaceDefinitionName.removeAll()
        }

        if newConfiguration.printConfiguration != oldConfiguration.printConfiguration {
            logger.debug("Print configuration changed, clearing interface cache")
            interfaceByName.removeAll()
        }
    }

    func allObjects() async throws -> [RuntimeObject] {
        logger.debug("Getting all Swift objects")
        let rootTypeName = try builder.indexer.rootTypeDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let rootProtocolName = try builder.indexer.rootProtocolDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let typeExtensionName = try builder.indexer.typeExtensionDefinitions.filter { $0.key.typeName.map { builder.indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeExtension($0.key)) }
        let protocolExtensionName = try builder.indexer.protocolExtensionDefinitions.filter { $0.key.protocolName.map { builder.indexer.allProtocolDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .protocolExtension($0.key)) }
        let typeAliasExtensionName = try builder.indexer.typeAliasExtensionDefinitions.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeAliasExtension($0.key)) }
        let conformanceExtensionName = try builder.indexer.conformanceExtensionDefinitions.filter { $0.key.typeName.map { builder.indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftConformance, definitionName: .conformance($0.key)) }
        let allObjects = rootTypeName + rootProtocolName + typeExtensionName + protocolExtensionName + typeAliasExtensionName + conformanceExtensionName
        logger.debug("Found \(allObjects.count, privacy: .public) Swift objects: \(rootTypeName.count, privacy: .public) types, \(rootProtocolName.count, privacy: .public) protocols, \(typeExtensionName.count, privacy: .public) type extensions")
        return allObjects
    }

    private func makeRuntimeObject(for extensionDefintions: [ExtensionDefinition], extensionName: ExtensionName, kind: RuntimeObjectKind, definitionName: InterfaceDefinitionName) throws -> RuntimeObject {
        let typeChildren = try extensionDefintions.flatMap { $0.types }.map { try makeRuntimeObject(for: $0, isChild: true) }
        let protocolChildren = try extensionDefintions.flatMap { $0.protocols }.map { try makeRuntimeObject(for: $0, isChild: true) }
        let mangledName = try mangleAsString(extensionName.node)
        let runtimeObjectName = RuntimeObject(name: mangledName, displayName: extensionName.name, kind: kind, secondaryKind: nil, imagePath: imagePath, children: typeChildren + protocolChildren)
        nameToInterfaceDefinitionName[runtimeObjectName] = definitionName
        return runtimeObjectName
    }
    
    private func makeRuntimeObject(for protocolDefintion: ProtocolDefinition, isChild: Bool) throws -> RuntimeObject {
        let mangledName = try mangleAsString(protocolDefintion.protocolName.node)
        let runtimeObjectName: RuntimeObject
        if isChild {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.currentName, kind: protocolDefintion.protocolName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: [])
            nameToInterfaceDefinitionName[runtimeObjectName] = .childProtocol(protocolDefintion.protocolName)
        } else {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.name, kind: protocolDefintion.protocolName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: [])
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootProtocol(protocolDefintion.protocolName)
        }
        return runtimeObjectName
    }

    private func makeRuntimeObject(for typeDefinition: TypeDefinition, isChild: Bool) throws -> RuntimeObject {
        let typeChildren = try typeDefinition.typeChildren.map { try makeRuntimeObject(for: $0, isChild: true) }
        let protocolChildren = try typeDefinition.protocolChildren.map { try makeRuntimeObject(for: $0, isChild: true) }
        let mangledName = try mangleAsString(typeDefinition.typeName.node)
        let runtimeObjectName: RuntimeObject
        if isChild {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: typeDefinition.typeName.currentName, kind: typeDefinition.typeName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: typeChildren + protocolChildren)
            nameToInterfaceDefinitionName[runtimeObjectName] = .childType(typeDefinition.typeName)
        } else {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: typeDefinition.typeName.name, kind: typeDefinition.typeName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: typeChildren + protocolChildren)
            nameToInterfaceDefinitionName[runtimeObjectName] = .rootType(typeDefinition.typeName)
        }
        return runtimeObjectName
    }

    func interface(for object: RuntimeObject) async throws -> RuntimeObjectInterface {
        logger.debug("Generating Swift interface for: \(object.name, privacy: .public)")
        if let interface = interfaceByName[object] {
            logger.debug("Using cached interface")
            return interface
        }

        guard let interfaceDefinitionName = nameToInterfaceDefinitionName[object] else {
            logger.warning("Invalid runtime object: \(object.name, privacy: .public)")
            throw Error.invalidRuntimeObject
        }
        var newInterfaceString: SemanticString = ""
        switch interfaceDefinitionName {
        case .rootType(let rootTypeName):
            guard let typeDefinition = builder.indexer.rootTypeDefinitions[rootTypeName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(builder.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = builder.indexer.typeExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = builder.indexer.conformanceExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childType(let childTypeName):
            guard let typeDefinition = builder.indexer.allTypeDefinitions[childTypeName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(builder.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = builder.indexer.typeExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = builder.indexer.conformanceExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .rootProtocol(let rootProtocolName):
            guard let definition = builder.indexer.rootProtocolDefinitions[rootProtocolName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(builder.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = builder.indexer.protocolExtensionDefinitions[rootProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childProtocol(let childProtocolName):
            guard let definition = builder.indexer.allProtocolDefinitions[childProtocolName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(builder.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = builder.indexer.protocolExtensionDefinitions[childProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .typeExtension(let typeExtensionName):
            guard let definitions = builder.indexer.typeExtensionDefinitions[typeExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .protocolExtension(let protocolExtensionName):
            guard let definitions = builder.indexer.protocolExtensionDefinitions[protocolExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .typeAliasExtension(let typeAliasExtensionName):
            guard let definitions = builder.indexer.typeAliasExtensionDefinitions[typeAliasExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .conformance(let conformanceExtensionName):
            guard let definitions = builder.indexer.conformanceExtensionDefinitions[conformanceExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await builder.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        }

        let newInterface = RuntimeObjectInterface(object: object, interfaceString: newInterfaceString)
        interfaceByName[object] = newInterface
        logger.debug("Interface generated and cached")
        return newInterface
    }

    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        logger.debug("Getting Swift class hierarchy for: \(object.name, privacy: .public)")
        guard case .swift(.type(.class)) = object.kind,
              let classDefinitionName = nameToInterfaceDefinitionName[object]?.typeName,
              let classDefinition = builder.indexer.allTypeDefinitions[classDefinitionName],
              case .class(let `class`) = classDefinition.type
        else {
            logger.debug("No class hierarchy found")
            return []
        }
        let hierarchy = try ClassHierarchyDumper(machO: machO).dump(for: `class`.descriptor)
        logger.debug("Class hierarchy: \(hierarchy.count, privacy: .public) levels")
        return hierarchy
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

@FrameworkToolboxExtension(.internal)
extension SwiftInterface.Definition {}
