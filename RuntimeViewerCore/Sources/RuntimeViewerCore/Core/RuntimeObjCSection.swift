import Foundation
import FoundationToolbox
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
private import RuntimeViewerCoreObjC
import Semantic
import Utilities
import MetaCodable

@Codable
public struct ObjCGenerationOptions: Sendable, Equatable {
    @Default(ifMissing: false)
    public var stripProtocolConformance: Bool = false
    @Default(ifMissing: false)
    public var stripOverrides: Bool = false
    @Default(ifMissing: false)
    public var stripSynthesizedIvars: Bool = false
    @Default(ifMissing: false)
    public var stripSynthesizedMethods: Bool = false
    @Default(ifMissing: false)
    public var stripCtorMethod: Bool = false
    @Default(ifMissing: false)
    public var stripDtorMethod: Bool = false
    @Default(ifMissing: false)
    public var addIvarOffsetComments: Bool = false
    @Default(ifMissing: false)
    public var addPropertyAttributesComments: Bool = false
}

@Loggable
actor RuntimeObjCSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private let factory: RuntimeObjCSectionFactory

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

    init(imagePath: String, factory: RuntimeObjCSectionFactory) async throws {
        #log(.info, "Initializing ObjC section for image: \(imagePath, privacy: .public)")
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else {
            #log(.error, "Failed to create MachOImage for: \(imageName, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.machO = machO
        self.imagePath = imagePath
        self.factory = factory
        try await prepare()
    }

    init(machO: MachOImage, factory: RuntimeObjCSectionFactory) async throws {
        #log(.info, "Initializing ObjC section from MachO: \(machO.imagePath, privacy: .public)")
        self.machO = machO
        self.imagePath = machO.imagePath
        self.factory = factory
        try await prepare()
    }

    private func prepare() async throws {
        #log(.debug, "Preparing ObjC section data")
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
        #log(.info, "ObjC section prepared: \(classByName.count, privacy: .public) classes, \(protocolByName.count, privacy: .public) protocols, \(categoryByName.count, privacy: .public) categories, \(structsByName.count, privacy: .public) structs, \(unionsByName.count, privacy: .public) unions")
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
        #log(.debug, "Getting all ObjC objects")
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

        #log(.debug, "Found \(results.count, privacy: .public) ObjC objects")
        return results
    }

    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration) async throws -> RuntimeObjectInterface {
        #log(.debug, "Generating interface for: \(object.name, privacy: .public)")
        let name = object.withImagePath(imagePath)
        let cTypeReplacements = transformer.cType.isEnabled ? transformer.cType.replacements : [:]
        let objcDumpContext = ObjCDumpContext(options: options, cTypeReplacements: cTypeReplacements) { name, isStruct in
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
        #log(.default, "Invalid runtime object: \(object.name, privacy: .public) kind: \(String(describing: object.kind), privacy: .public)")
        throw Error.invalidRuntimeObject
    }

    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        #log(.debug, "Getting class hierarchy for: \(object.name, privacy: .public)")
        guard case .objc(.type(.class)) = object.kind,
              let classGroups = classes[object.name]
        else {
            #log(.debug, "No class hierarchy found")
            return []
        }
        let hierarchy = classGroups.info.map(\.name)
        #log(.debug, "Class hierarchy: \(hierarchy.count, privacy: .public) levels")
        return hierarchy
    }
}

@Loggable
actor RuntimeObjCSectionFactory {
    private var sections: [String: RuntimeObjCSection] = [:]

    func existingSection(for imagePath: String) -> RuntimeObjCSection? {
        sections[imagePath]
    }

    func section(for imagePath: String) async throws -> RuntimeObjCSection {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached ObjC section for: \(imagePath, privacy: .public)")
            return section
        }
        #log(.debug, "Creating ObjC section for: \(imagePath, privacy: .public)")
        let section = try await RuntimeObjCSection(imagePath: imagePath, factory: self)
        sections[imagePath] = section
        #log(.debug, "ObjC section created and cached")
        return section
    }

    func section(for name: RuntimeObjCName) async throws -> RuntimeObjCSection? {
        #log(.debug, "Looking up ObjC section for name: \(String(describing: name), privacy: .public)")
        do {
            guard let machO = MachOImage.image(forName: name) else {
                #log(.debug, "No MachO image found for name")
                return nil
            }

            if let existObjCSection = sections[machO.imagePath] {
                #log(.debug, "Using cached ObjC section")
                return existObjCSection
            }

            #log(.debug, "Creating ObjC section from MachO: \(machO.imagePath, privacy: .public)")
            let objcSection = try await RuntimeObjCSection(machO: machO, factory: self)
            sections[machO.imagePath] = objcSection
            return objcSection
        } catch {
            #log(.error, "Failed to create ObjC section: \(error, privacy: .public)")
            return nil
        }
    }

    func removeSection(for imagePath: String) {
        sections.removeValue(forKey: imagePath)
    }

    func removeAllSections() {
        sections.removeAll()
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
