import Foundation
import Semantic
import OrderedCollections
import MachOKit
import MachOSwiftSection
import SwiftDump

public final class RuntimeSwiftSections {
    private typealias SwiftEnum = MachOSwiftSection.Enum
    private typealias SwiftStruct = MachOSwiftSection.Struct
    private typealias SwiftClass = MachOSwiftSection.Class
    private typealias SwiftProtocol = MachOSwiftSection.`Protocol`
    private typealias SwiftProtocolConformance = MachOSwiftSection.ProtocolConformance
    private typealias SwiftAssociatedType = MachOSwiftSection.AssociatedType

    public enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
    }

    public let imagePath: String

    private let machO: MachOImage

    private let enums: [SwiftEnum]

    private let structs: [SwiftStruct]

    private let classes: [SwiftClass]

    private let protocols: [SwiftProtocol]

    private let protocolConformances: [SwiftProtocolConformance]

    private let associatedTypes: [AssociatedType]

    private var enumByName: OrderedDictionary<RuntimeObjectName, SwiftEnum> = [:]

    private var structByName: OrderedDictionary<RuntimeObjectName, SwiftStruct> = [:]

    private var classByName: OrderedDictionary<RuntimeObjectName, SwiftClass> = [:]

    private var protocolByName: OrderedDictionary<RuntimeObjectName, SwiftProtocol> = [:]

    private var protocolConformanceByTypeName: OrderedDictionary<String, [SwiftProtocolConformance]> = [:]

    private var protocolConformanceByProtocolName: OrderedDictionary<String, [SwiftProtocolConformance]> = [:]

    private var associatedTypeByTypeName: OrderedDictionary<String, [SwiftAssociatedType]> = [:]

    private var associatedTypeByProtocolName: OrderedDictionary<String, [SwiftAssociatedType]> = [:]

    private var interfaceByName: OrderedDictionary<RuntimeObjectName, RuntimeObjectInterface> = [:]

    public init(imagePath: String) throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension
        guard !imageName.starts(with: "libswift") else {
            throw Error.invalidMachOImage
        }
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }

        var enums: [MachOSwiftSection.Enum] = []
        var structs: [MachOSwiftSection.Struct] = []
        var classes: [MachOSwiftSection.Class] = []
        var protocols: [MachOSwiftSection.`Protocol`] = []
        var protocolConformances: [MachOSwiftSection.ProtocolConformance] = []
        var associatedTypes: [MachOSwiftSection.AssociatedType] = []
        for typeContextDescriptor in (try? machO.swift.typeContextDescriptors) ?? [] {
            switch typeContextDescriptor {
            case .enum(let enumDescriptor):
                try enums.append(Enum(descriptor: enumDescriptor, in: machO))
            case .struct(let structDescriptor):
                try structs.append(Struct(descriptor: structDescriptor, in: machO))
            case .class(let classDescriptor):
                try classes.append(Class(descriptor: classDescriptor, in: machO))
            }
        }

        for protocolDescriptor in (try? machO.swift.protocolDescriptors) ?? [] {
            try protocols.append(MachOSwiftSection.`Protocol`(descriptor: protocolDescriptor, in: machO))
        }

        for protocolConformanceDescriptor in (try? machO.swift.protocolConformanceDescriptors) ?? [] {
            try protocolConformances.append(MachOSwiftSection.ProtocolConformance(descriptor: protocolConformanceDescriptor, in: machO))
        }

        for associatedTypeDescriptor in (try? machO.swift.associatedTypeDescriptors) ?? [] {
            try associatedTypes.append(MachOSwiftSection.AssociatedType(descriptor: associatedTypeDescriptor, in: machO))
        }

        self.imagePath = imagePath
        self.machO = machO
        self.classes = classes
        self.structs = structs
        self.enums = enums
        self.protocols = protocols
        self.protocolConformances = protocolConformances
        self.associatedTypes = associatedTypes

        for protocolConformance in protocolConformances {
            try protocolConformanceByTypeName[protocolConformance.dumpTypeName(using: .interface, in: machO).string, default: []].append(protocolConformance)
            try protocolConformanceByProtocolName[protocolConformance.dumpProtocolName(using: .interface, in: machO).string, default: []].append(protocolConformance)
        }

        for associatedType in associatedTypes {
            try associatedTypeByTypeName[associatedType.dumpTypeName(using: .interface, in: machO).string, default: []].append(associatedType)
            try associatedTypeByProtocolName[associatedType.dumpProtocolName(using: .interface, in: machO).string, default: []].append(associatedType)
        }
    }

    public func enumNames() throws -> [RuntimeObjectName] {
        enumByName.removeAll()
        var names: OrderedSet<RuntimeObjectName> = []
        for `enum` in enums {
            let name = try name(for: `enum`, kind: .swift(.enum))
            enumByName[name] = `enum`
            names.append(name)
        }
        return names.elements
    }

    public func structNames() throws -> [RuntimeObjectName] {
        structByName.removeAll()
        var names: OrderedSet<RuntimeObjectName> = []
        for `struct` in structs {
            let name = try name(for: `struct`, kind: .swift(.struct))
            structByName[name] = `struct`
            names.append(name)
        }
        return names.elements
    }

    public func classNames() throws -> [RuntimeObjectName] {
        classByName.removeAll()
        var names: OrderedSet<RuntimeObjectName> = []
        for `class` in classes {
            let name = try name(for: `class`, kind: .swift(.class))
            classByName[name] = `class`
            names.append(name)
        }
        return names.elements
    }

    public func protocolNames() throws -> [RuntimeObjectName] {
        protocolByName.removeAll()
        var names: OrderedSet<RuntimeObjectName> = []
        for `protocol` in protocols {
            let name = try name(for: `protocol`, kind: .swift(.protocol))
            protocolByName[name] = `protocol`
            names.append(name)
        }
        return names.elements
    }

    private func name<T: NamedDumpable>(for dumpable: T, kind: RuntimeObjectKind) throws -> RuntimeObjectName {
        try .init(name: dumpable.dumpName(using: .interface, in: machO).string, kind: kind, imagePath: imagePath)
    }

    public func interface(for name: RuntimeObjectName, options: DemangleOptions) throws -> RuntimeObjectInterface {
        guard case .swift(let swift) = name.kind else {
            throw Error.invalidRuntimeObjectName
        }
        var newInterfaceString: SemanticString?
        switch swift {
        case .enum:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `enum` = enumByName[name] {
                newInterfaceString = try `enum`.dump(using: options, in: machO)
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .struct:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `struct` = structByName[name] {
                newInterfaceString = try `struct`.dump(using: options, in: machO)
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .class:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `class` = classByName[name] {
                newInterfaceString = try `class`.dump(using: options, in: machO)
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .protocol:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `protocol` = protocolByName[name] {
                newInterfaceString = try `protocol`.dump(using: options, in: machO)
            } else {
                throw Error.invalidRuntimeObjectName
            }
        }
        if var newInterfaceString {
            switch swift {
            case .enum,
                 .struct,
                 .class:
                if let protocolConformances = protocolConformanceByTypeName[name.name] {
                    for protocolConformance in protocolConformances {
                        newInterfaceString.append("\n\n", type: .standard)
                        try newInterfaceString.append(protocolConformance.dump(using: options, in: machO))
                    }
                }

                if let associatedTypes = associatedTypeByTypeName[name.name] {
                    for associatedType in associatedTypes {
                        newInterfaceString.append("\n\n", type: .standard)
                        try newInterfaceString.append(associatedType.dump(using: options, in: machO))
                    }
                }
            case .protocol:
                if let protocolConformances = protocolConformanceByProtocolName[name.name] {
                    for protocolConformance in protocolConformances {
                        newInterfaceString.append("\n\n", type: .standard)
                        try newInterfaceString.append(protocolConformance.dump(using: options, in: machO))
                    }
                }

                if let associatedTypes = associatedTypeByProtocolName[name.name] {
                    for associatedType in associatedTypes {
                        newInterfaceString.append("\n\n", type: .standard)
                        try newInterfaceString.append(associatedType.dump(using: options, in: machO))
                    }
                }
            }

            let newInterface = RuntimeObjectInterface(name: name, interfaceString: newInterfaceString)
            interfaceByName[name] = newInterface
            return newInterface
        } else {
            throw Error.invalidRuntimeObjectName
        }
    }
}
