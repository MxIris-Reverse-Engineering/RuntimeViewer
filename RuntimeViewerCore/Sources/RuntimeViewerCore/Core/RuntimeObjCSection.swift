import Foundation
import Semantic
import Utilities
import ObjCDump
import Logging
import ObjCTypeDecodeKit
import MachOObjCSection
import FoundationToolbox
import OrderedCollections
import RuntimeViewerObjC

public struct ObjCGenerationOptions: Sendable, Codable, Equatable {
    public var stripProtocolConformance: Bool = false
    public var stripOverrides: Bool = false
    public var stripSynthesizedIvars: Bool = false
    public var stripSynthesizedMethods: Bool = false
    public var stripCtorMethod: Bool = false
    public var stripDtorMethod: Bool = false
    public var addIvarOffsetComments: Bool = false
    public var addPropertyAttributesComments: Bool = false
}

actor RuntimeObjCSection {
    
    private static let logger: Logger = .init(label: "RuntimeObjCSection")
    
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private var classes: [String: ObjCClassGroup] = [:]

    private var protocols: [String: ObjCProtocolGroup] = [:]

    private var categories: [String: ObjCCategoryGroup] = [:]

    private var classInfoCache: [String: ObjCClassInfo] = [:]

    private var structs: [String: CStructOrUnion] = [:]

    private var unions: [String: CStructOrUnion] = [:]

    private typealias ObjCClassGroup = (objcClass: any ObjCClassProtocol, info: [ObjCClassInfo])

    private typealias ObjCProtocolGroup = (objcProtocol: any ObjCProtocolProtocol, info: ObjCProtocolInfo)

    private typealias ObjCCategoryGroup = (objcCategory: any ObjCCategoryProtocol, info: ObjCCategoryInfo)

    private enum ObjCName: Hashable {
        case `class`(String)
        case `protocol`(String)
        case category(String)
    }

    private struct CStructOrUnion: Hashable {
        let name: String

        let fields: [ObjCField]

        var hasBitFieldOnly: Bool {
            fields.allSatisfy { $0.bitWidth != nil }
        }

        var numberOfHasNameFields: Int {
            fields.count { $0.name != nil }
        }

        @SemanticStringBuilder
        func semanticString(isStruct: Bool, context: ObjCDumpContext) -> SemanticString {
            Keyword(isStruct ? "struct" : "union")
            Space()
            TypeName(kind: .other, name)
            Joined {
                MemberList(level: 1) {
                    for (index, field) in fields.enumerated() {
                        field.semanticString(fallbackName: "x\(index)", level: 1, context: context)
                    }
                }
            } prefix: {
                " {"
            } suffix: {
                Indent(level: 0)
                "}"
            }
        }
    }
    
    init(ptr: UnsafeRawPointer) async throws {
        guard let machO = MachOImage.image(for: ptr) else { throw Error.invalidMachOImage }
        try await self.init(machO: machO)
    }

    init(imagePath: String) async throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }
        self.machO = machO
        self.imagePath = imagePath
        try await prepare()
    }

    init(machO: MachOImage) async throws {
        self.machO = machO
        self.imagePath = machO.imagePath
        try await prepare()
    }

    private func prepare() async throws {
        var classByName: [String: ObjCClassGroup] = [:]
        var protocolByName: [String: ObjCProtocolGroup] = [:]
        var categoryByName: [String: ObjCCategoryGroup] = [:]
        var structsByName: [String: CStructOrUnion] = [:]
        var unionsByName: [String: CStructOrUnion] = [:]

        func setObjCType(_ type: ObjCType, forName objcName: ObjCName) {
            switch type {
            case .struct(let name, let fields):
                if let name {
                    let newStruct = CStructOrUnion(name: name, fields: fields ?? [])
                    guard !newStruct.hasBitFieldOnly else { return }
                    if let existStruct = structsByName[name] {
                        if existStruct.numberOfHasNameFields < newStruct.numberOfHasNameFields {
                            structsByName[name] = newStruct
                        }
                    } else {
                        structsByName[name] = newStruct
                    }
                }
            case .union(let name, let fields):
                if let name {
                    let newUnion = CStructOrUnion(name: name, fields: fields ?? [])
                    guard !newUnion.hasBitFieldOnly else { return }
                    if let existUnion = unionsByName[name] {
                        if existUnion.numberOfHasNameFields < newUnion.numberOfHasNameFields {
                            unionsByName[name] = newUnion
                        }
                    } else {
                        unionsByName[name] = newUnion
                    }
                }
            default:
                break
            }
        }

        func setObjCTypeFromMethods(_ methods: [ObjCMethodInfo], forName objcName: ObjCName) {
            for method in methods {
                if let returnType = method.returnType {
                    setObjCType(returnType, forName: objcName)
                }

                if let argumentInfos = method.argumentInfos {
                    for argumentInfo in argumentInfos {
                        setObjCType(argumentInfo.type, forName: objcName)
                    }
                }
            }
        }

        func setObjCTypeFromProperties(_ properties: [ObjCPropertyInfo], forName objcName: ObjCName) {
            for property in properties {
                for attribute in property.attributes {
                    if let type = attribute.type {
                        setObjCType(type, forName: objcName)
                    }
                }
            }
        }

        let objcClasses: [any ObjCClassProtocol] = machO.objc.classes64.orEmpty + machO.objc.classes32.orEmpty + machO.objc.nonLazyClasses64.orEmpty + machO.objc.nonLazyClasses32.orEmpty

        for objcClass in objcClasses {
            let objcClassGroup: ObjCClassGroup = (objcClass, infoWithSuperclasses(class: objcClass, in: machO))
            guard let objcClassInfo = objcClassGroup.info.first else { continue }
            classByName[objcClassInfo.name] = objcClassGroup

            let objcName = ObjCName.class(objcClassInfo.name)

            for ivar in objcClassInfo.ivars {
                if let type = ivar.type {
                    setObjCType(type, forName: objcName)
                }
            }

            setObjCTypeFromProperties(objcClassInfo.properties + objcClassInfo.classProperties, forName: objcName)
            setObjCTypeFromMethods(objcClassInfo.methods + objcClassInfo.classMethods, forName: objcName)
        }

        let objcProtocols: [any ObjCProtocolProtocol] = machO.objc.protocols64.orEmpty + machO.objc.protocols32.orEmpty

        for objcProtocol in objcProtocols {
            guard let objcProtocolInfo = objcProtocol.info(in: machO) else { continue }
            protocolByName[objcProtocolInfo.name] = (objcProtocol, objcProtocolInfo)
            let objcName = ObjCName.protocol(objcProtocolInfo.name)
            setObjCTypeFromProperties(objcProtocolInfo.properties + objcProtocolInfo.classProperties, forName: objcName)
            setObjCTypeFromMethods(objcProtocolInfo.methods + objcProtocolInfo.classMethods, forName: objcName)
        }

        var objcCategories: [any ObjCCategoryProtocol] = []

        objcCategories.append(contentsOf: machO.objc.categories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.nonLazyCategories32.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_64.orEmpty)
        objcCategories.append(contentsOf: machO.objc.categories2_32.orEmpty)

        for objcCategory in objcCategories {
            guard let objcCategoryInfo = objcCategory.info(in: machO) else { continue }
            categoryByName[objcCategoryInfo.uniqueName] = (objcCategory, objcCategoryInfo)
            let objcName = ObjCName.category(objcCategoryInfo.uniqueName)
            setObjCTypeFromProperties(objcCategoryInfo.properties + objcCategoryInfo.classProperties, forName: objcName)
            setObjCTypeFromMethods(objcCategoryInfo.methods + objcCategoryInfo.classMethods, forName: objcName)
        }

        classes = classByName
        protocols = protocolByName
        categories = categoryByName
        structs = structsByName
        unions = unionsByName
    }

    private func infoWithSuperclasses<Class: ObjCClassProtocol>(class cls: Class, in machO: MachOImage) -> [ObjCClassInfo] {
        guard let className = cls.name(in: machO) else { return [] }

        var currentInfo: ObjCClassInfo?

        if let cacheInfo = classInfoCache[className] {
            currentInfo = cacheInfo
        } else {
            let info = cls.info(in: machO)
            currentInfo = info
            classInfoCache[className] = info
        }

        guard let currentInfo else { return [] }

        var resultInfos: [ObjCClassInfo] = [currentInfo]

        var machOAndSuperclass = cls.superClass(in: machO) // else { return resultInfos }

        while let currentMachOAndSuperclass = machOAndSuperclass {
            let currentMachO = currentMachOAndSuperclass.0
            let currentSuperclass = currentMachOAndSuperclass.1

            machOAndSuperclass = currentSuperclass.superClass(in: currentMachO)

            guard let superClassName = currentSuperclass.name(in: currentMachO) else { continue }

            var superclassInfo: ObjCClassInfo?
            if let cacheInfo = classInfoCache[superClassName] {
                superclassInfo = cacheInfo
            } else {
                let info = currentSuperclass.info(in: currentMachO)
                superclassInfo = info
                classInfoCache[superClassName] = info
            }
            if let superclassInfo {
                resultInfos.append(superclassInfo)
            }
        }

        return resultInfos
    }

    func allObjects() async throws -> [RuntimeObject] {
        var results: [RuntimeObject] = []

        for structName in structs.keys {
            results.append(.init(name: structName, displayName: structName, kind: .c(.struct), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for unionName in unions.keys {
            results.append(.init(name: unionName, displayName: unionName, kind: .c(.union), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for (className, objcClassGroup) in classes {
            results.append(.init(name: className, displayName: className, kind: .objc(.type(.class)), secondaryKind: objcClassGroup.objcClass.isSwiftStable ? .swift(.type(.class)) : nil, imagePath: imagePath, children: []))
        }

        for proto in protocols.keys {
            results.append(.init(name: proto, displayName: proto, kind: .objc(.type(.protocol)), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for category in categories.keys {
            results.append(.init(name: category, displayName: category, kind: .objc(.category(.class)), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        return results
    }

    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions) async throws -> RuntimeObjectInterface {
        let name = object.withImagePath(imagePath)
        let objcDumpContext = ObjCDumpContext(options: options) { name, isStruct in
            guard let name else { return true }
            if isStruct {
                return self.structs[name] == nil
            } else {
                return self.unions[name] == nil
            }
        }

        switch name.kind {
        case .objc(.type(.class)):
            if let classGroup = classes[name.name], let currentClassInfo = classGroup.info.first {
                let superclassInfos = classGroup.info.dropFirst()
                var finalClassInfo = classGroup.info.first
                var needsStripClassProperties: Set<String> = []
                var needsStripProperties: Set<String> = []
                var needsStripClassMethods: Set<String> = []
                var needsStripMethods: Set<String> = []
                var needsStripIvars: Set<String> = []

                if options.stripCtorMethod {
                    needsStripMethods.insert(".cxx_construct")
                }

                if options.stripDtorMethod {
                    needsStripMethods.insert(".cxx_destruct")
                }

                if options.stripOverrides {
                    for superclassInfo in superclassInfos {
                        needsStripClassProperties.insert(contentsOf: superclassInfo.classProperties.map(\.name))
                        needsStripProperties.insert(contentsOf: superclassInfo.properties.map(\.name))
                        needsStripClassMethods.insert(contentsOf: superclassInfo.classMethods.map(\.name))
                        needsStripMethods.insert(contentsOf: superclassInfo.methods.map(\.name))
                    }
                }
                if options.stripProtocolConformance {
                    for protocolInfo in currentClassInfo.protocols {
                        needsStripClassProperties.insert(contentsOf: protocolInfo.classProperties.map(\.name))
                        needsStripProperties.insert(contentsOf: protocolInfo.properties.map(\.name))
                        needsStripClassMethods.insert(contentsOf: protocolInfo.classMethods.map(\.name))
                        needsStripMethods.insert(contentsOf: protocolInfo.methods.map(\.name))
                    }
                }
                if options.stripSynthesizedIvars || options.stripSynthesizedMethods {
                    var needsStripIvarNames: Set<String> = []

                    for property in currentClassInfo.properties + currentClassInfo.classProperties {
                        if options.stripSynthesizedMethods {
                            let propertyName = property.name
                            if let customGetter = property.customGetter {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(customGetter)
                                } else {
                                    needsStripMethods.insert(customGetter)
                                }
                            } else {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(propertyName)
                                } else {
                                    needsStripMethods.insert(propertyName)
                                }
                            }

                            if let customSetter = property.customSetter {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(customSetter)
                                } else {
                                    needsStripMethods.insert(customSetter)
                                }
                            } else {
                                let setterMethodName = "set" + propertyName.uppercasedFirst
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(setterMethodName)
                                } else {
                                    needsStripMethods.insert(setterMethodName)
                                }
                            }
                        }

                        if options.stripSynthesizedIvars, !property.isClassProperty {
                            if let ivar = property.ivar {
                                needsStripIvarNames.insert(ivar)
                            }
                        }
                    }

                    if options.stripSynthesizedIvars {
                        for ivar in currentClassInfo.ivars {
                            if needsStripIvarNames.contains(ivar.name) {
                                needsStripIvars.insert(ivar.name)
                            }
                        }
                    }
                }

                finalClassInfo = ObjCClassInfo(
                    name: currentClassInfo.name,
                    version: currentClassInfo.version,
                    imageName: currentClassInfo.imageName,
                    instanceSize: currentClassInfo.instanceSize,
                    superClassName: currentClassInfo.superClassName,
                    protocols: currentClassInfo.protocols,
                    ivars: currentClassInfo.ivars.removingAll { needsStripIvars.contains($0.name) },
                    classProperties: currentClassInfo.classProperties.removingAll { needsStripClassProperties.contains($0.name) },
                    properties: currentClassInfo.properties.removingAll { needsStripProperties.contains($0.name) },
                    classMethods: currentClassInfo.classMethods.removingAll { needsStripClassMethods.contains($0.name) },
                    methods: currentClassInfo.methods.removingAll { needsStripMethods.contains($0.name) }
                )

                if let finalClassInfo {
                    return .init(object: name, interfaceString: finalClassInfo.semanticString(using: objcDumpContext))
                }
            }
        case .objc(.type(.protocol)):
            if let currentProtocolInfo = protocols[name.name]?.info {
                var finalProtocolInfo = currentProtocolInfo

                var needsStripClassProperties: Set<String> = []
                var needsStripClassMethods: Set<String> = []
                var needsStripProperties: Set<String> = []
                var needsStripMethods: Set<String> = []

                if options.stripCtorMethod {
                    needsStripMethods.insert(".cxx_construct")
                }

                if options.stripDtorMethod {
                    needsStripMethods.insert(".cxx_destruct")
                }

                if options.stripProtocolConformance {
                    for protocolInfo in currentProtocolInfo.protocols {
                        needsStripClassProperties.insert(contentsOf: protocolInfo.classProperties.map(\.name))
                        needsStripProperties.insert(contentsOf: protocolInfo.properties.map(\.name))
                        needsStripClassMethods.insert(contentsOf: protocolInfo.classMethods.map(\.name))
                        needsStripMethods.insert(contentsOf: protocolInfo.methods.map(\.name))

                        needsStripClassProperties.insert(contentsOf: protocolInfo.optionalClassProperties.map(\.name))
                        needsStripProperties.insert(contentsOf: protocolInfo.optionalProperties.map(\.name))
                        needsStripClassMethods.insert(contentsOf: protocolInfo.optionalClassMethods.map(\.name))
                        needsStripMethods.insert(contentsOf: protocolInfo.optionalMethods.map(\.name))
                    }
                }

                if options.stripSynthesizedMethods {
                    for property in currentProtocolInfo.properties + currentProtocolInfo.classProperties + currentProtocolInfo.optionalProperties + currentProtocolInfo.optionalClassProperties {
                        if options.stripSynthesizedMethods {
                            let propertyName = property.name
                            if let customGetter = property.customGetter {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(customGetter)
                                } else {
                                    needsStripMethods.insert(customGetter)
                                }
                            } else {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(propertyName)
                                } else {
                                    needsStripMethods.insert(propertyName)
                                }
                            }

                            if let customSetter = property.customSetter {
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(customSetter)
                                } else {
                                    needsStripMethods.insert(customSetter)
                                }
                            } else {
                                let setterMethodName = "set" + propertyName.uppercasedFirst
                                if property.isClassProperty {
                                    needsStripClassMethods.insert(setterMethodName)
                                } else {
                                    needsStripMethods.insert(setterMethodName)
                                }
                            }
                        }
                    }
                }

                finalProtocolInfo = ObjCProtocolInfo(
                    name: currentProtocolInfo.name,
                    protocols: currentProtocolInfo.protocols,
                    classProperties: currentProtocolInfo.classProperties.removingAll { needsStripClassProperties.contains($0.name) },
                    properties: currentProtocolInfo.properties.removingAll { needsStripProperties.contains($0.name) },
                    classMethods: currentProtocolInfo.classMethods.removingAll { needsStripClassMethods.contains($0.name) },
                    methods: currentProtocolInfo.methods.removingAll { needsStripMethods.contains($0.name) },
                    optionalClassProperties: currentProtocolInfo.optionalClassProperties.removingAll { needsStripClassProperties.contains($0.name) },
                    optionalProperties: currentProtocolInfo.optionalProperties.removingAll { needsStripProperties.contains($0.name) },
                    optionalClassMethods: currentProtocolInfo.optionalClassMethods.removingAll { needsStripClassMethods.contains($0.name) },
                    optionalMethods: currentProtocolInfo.optionalMethods.removingAll { needsStripMethods.contains($0.name) }
                )

                return .init(object: name, interfaceString: finalProtocolInfo.semanticString(using: objcDumpContext))
            }
        case .objc(.category(.class)):
            if let interfaceString = categories[name.name]?.info.semanticString(using: objcDumpContext) {
                return .init(object: name, interfaceString: interfaceString)
            }
        case .c(.struct):
            if let interfaceString = structs[name.name]?.semanticString(isStruct: true, context: objcDumpContext) {
                return .init(object: name, interfaceString: interfaceString)
            }
        case .c(.union):
            if let interfaceString = unions[name.name]?.semanticString(isStruct: false, context: objcDumpContext) {
                return .init(object: name, interfaceString: interfaceString)
            }
        default:
            break
        }
        throw Error.invalidRuntimeObject
    }

    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        guard case .objc(.type(.class)) = object.kind,
              let classGroups = classes[object.name]
        else { return [] }
        return classGroups.info.map(\.name)
    }
}

enum RuntimeObjCName {
    case `class`(String)
    case `protocol`(String)
}

extension MachOImage {

    static func image(forName name: RuntimeObjCName) -> Self? {
        switch name {
        case .class(let string):
            return .image(forClassName: string)
        case .protocol(let string):
            return .image(forProtocolName: string)
        }
    }

    static func image(forClassName className: String) -> Self? {
        RVClassFromString(className).flatMap { MachOImage.image(for: autoBitCast($0)) }
    }

    static func image(forProtocolName protocolName: String) -> Self? {
        RVProtocolFromString(protocolName).flatMap { MachOImage.image(for: autoBitCast($0)) }
    }
}
