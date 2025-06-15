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
    
    public enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
    }

    public let imageName: String

    private let machO: MachOImage

    private let enums: [SwiftEnum]

    private let structs: [SwiftStruct]

    private let classes: [SwiftClass]

    private let protocols: [SwiftProtocol]

    private let protocolConformances: [SwiftProtocolConformance]

    private var enumByName: OrderedDictionary<RuntimeObjectName, SwiftEnum> = [:]
    
    private var structByName: OrderedDictionary<RuntimeObjectName, SwiftStruct> = [:]
    
    private var classByName: OrderedDictionary<RuntimeObjectName, SwiftClass> = [:]
    
    private var protocolByName: OrderedDictionary<RuntimeObjectName, SwiftProtocol> = [:]

    private var interfaceByName: OrderedDictionary<RuntimeObjectName, RuntimeObjectInterface> = [:]
    
    public init(imageName: String) throws {
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }

        var classes: [MachOSwiftSection.Class] = []
        var structs: [MachOSwiftSection.Struct] = []
        var enums: [MachOSwiftSection.Enum] = []
        var protocols: [MachOSwiftSection.`Protocol`] = []
        var protocolConformances: [MachOSwiftSection.ProtocolConformance] = []
        for type in try machO.swift.typeContextDescriptors {
            switch type {
            case .type(let typeContextDescriptorWrapper):
                switch typeContextDescriptorWrapper {
                case .enum(let enumDescriptor):
                    try enums.append(Enum(descriptor: enumDescriptor, in: machO))
                case .struct(let structDescriptor):
                    try structs.append(Struct(descriptor: structDescriptor, in: machO))
                case .class(let classDescriptor):
                    try classes.append(Class(descriptor: classDescriptor, in: machO))
                }
            default:
                continue
            }
        }

        for protocolDescriptor in try machO.swift.protocolDescriptors {
            try protocols.append(MachOSwiftSection.`Protocol`(descriptor: protocolDescriptor, in: machO))
        }

        for protocolConformanceDescriptor in try machO.swift.protocolConformanceDescriptors {
            try protocolConformances.append(MachOSwiftSection.ProtocolConformance(descriptor: protocolConformanceDescriptor, in: machO))
        }

        self.imageName = imageName
        self.machO = machO
        self.classes = classes
        self.structs = structs
        self.enums = enums
        self.protocols = protocols
        self.protocolConformances = protocolConformances
    }

    public func enumNames() throws -> [RuntimeObjectName] {
        enumByName.removeAll()
        var names: [RuntimeObjectName] = []
        for `enum` in enums {
            let name = try name(for: `enum`, kind: .swift(.enum))
            enumByName[name] = `enum`
            names.append(name)
        }
        return names
    }

    public func structNames() throws -> [RuntimeObjectName] {
        structByName.removeAll()
        var names: [RuntimeObjectName] = []
        for `struct` in structs {
            let name = try name(for: `struct`, kind: .swift(.struct))
            structByName[name] = `struct`
            names.append(name)
        }
        return names
    }

    public func classNames() throws -> [RuntimeObjectName] {
        classByName.removeAll()
        var names: [RuntimeObjectName] = []
        for `class` in classes {
            let name = try name(for: `class`, kind: .swift(.class))
            classByName[name] = `class`
            names.append(name)
        }
        return names
    }

    public func protocolNames() throws -> [RuntimeObjectName] {
        protocolByName.removeAll()
        var names: [RuntimeObjectName] = []
        for `protocol` in protocols {
            let name = try name(for: `protocol`, kind: .swift(.protocol))
            protocolByName[name] = `protocol`
            names.append(name)
        }
        return names
    }
    
    private func name<T: NamedDumpable>(for dumpable: T, kind: RuntimeObjectKind) throws -> RuntimeObjectName {
        try .init(name: dumpable.dumpName(using: .interface, in: machO).string, kind: kind)
    }

    public func interface(for name: RuntimeObjectName, options: DemangleOptions) throws -> RuntimeObjectInterface {
        guard case .swift(let swift) = name.kind else {
            throw Error.invalidRuntimeObjectName
        }
        switch swift {
        case .enum:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `enum` = enumByName[name] {
                let interface = try RuntimeObjectInterface(name: name, interfaceString: `enum`.dump(using: options, in: machO))
                interfaceByName[name] = interface
                return interface
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .struct:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `struct` = structByName[name] {
                let interface = try RuntimeObjectInterface(name: name, interfaceString: `struct`.dump(using: options, in: machO))
                interfaceByName[name] = interface
                return interface
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .class:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `class` = classByName[name] {
                let interface = try RuntimeObjectInterface(name: name, interfaceString: `class`.dump(using: options, in: machO))
                interfaceByName[name] = interface
                return interface
            } else {
                throw Error.invalidRuntimeObjectName
            }
        case .protocol:
            if let interface = interfaceByName[name] {
                return interface
            } else if let `protocol` = protocolByName[name] {
                let interface = try RuntimeObjectInterface(name: name, interfaceString: `protocol`.dump(using: options, in: machO))
                interfaceByName[name] = interface
                return interface
            } else {
                throw Error.invalidRuntimeObjectName
            }
        }
    }
}
