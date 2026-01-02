import Foundation
import Semantic
import Utilities
import ObjCDump
import ObjCTypeDecodeKit
import MachOObjCSection
import FoundationToolbox
import OrderedCollections

public struct ObjCGenerationOptions: Sendable, Codable, Equatable {
    public var stripProtocolConformance: Bool = false
    public var stripOverrides: Bool = false
    public var stripSynthesizedIvars: Bool = false
    public var stripSynthesizedMethods: Bool = false
    public var addIvarOffsetComments: Bool = false
}

actor RuntimeObjCSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
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
        func semanticString(isStruct: Bool, isExpandHandler: (String?, Bool) -> Bool = { _, _ in true }) -> SemanticString {
            Keyword(isStruct ? "struct" : "union")
            Space()
            TypeName(kind: .other, name)
            Joined {
                MemberList(level: 1) {
                    for (index, field) in fields.enumerated() {
                        field.semanticString(fallbackName: "x\(index)", level: 1, isExpandHandler: isExpandHandler)
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

    init(imagePath: String) async throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }
        self.imagePath = imagePath
        self.machO = machO
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

    func allNames() async throws -> [RuntimeObjectName] {
        var results: [RuntimeObjectName] = []

        for structName in structs.keys {
            results.append(.init(name: structName, displayName: structName, kind: .c(.struct), imagePath: imagePath, children: []))
        }

        for unionName in unions.keys {
            results.append(.init(name: unionName, displayName: unionName, kind: .c(.union), imagePath: imagePath, children: []))
        }

        for cls in classes.keys {
            results.append(.init(name: cls, displayName: cls, kind: .objc(.type(.class)), imagePath: imagePath, children: []))
        }

        for proto in protocols.keys {
            results.append(.init(name: proto, displayName: proto, kind: .objc(.type(.protocol)), imagePath: imagePath, children: []))
        }

        for category in categories.keys {
            results.append(.init(name: category, displayName: category, kind: .objc(.category(.class)), imagePath: imagePath, children: []))
        }

        return results
    }

    func interface(for name: RuntimeObjectName, using options: ObjCGenerationOptions) async throws -> RuntimeObjectInterface {
        let isExpandHandler: (String?, Bool) -> Bool = { name, isStruct in
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

                    for property in currentClassInfo.properties {
                        if options.stripSynthesizedMethods {
                            let propertyName = property.name
                            if let customGetter = property.customGetter {
                                needsStripMethods.insert(customGetter)
                            } else {
                                needsStripMethods.insert(propertyName)
                            }

                            if let customSetter = property.customSetter {
                                needsStripMethods.insert(customSetter)
                            } else {
                                needsStripMethods.insert("set" + propertyName.uppercasedFirst)
                            }
                        }

                        if options.stripSynthesizedIvars {
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
                    return .init(name: name, interfaceString: finalClassInfo.semanticString(using: options, isExpandHandler: isExpandHandler))
                }
            }
        case .objc(.type(.protocol)):
            if let interfaceString = protocols[name.name]?.info.semanticString(using: options, isExpandHandler: isExpandHandler) {
                return .init(name: name, interfaceString: interfaceString)
            }
        case .objc(.category(.class)):
            if let interfaceString = categories[name.name]?.info.semanticString(using: options, isExpandHandler: isExpandHandler) {
                return .init(name: name, interfaceString: interfaceString)
            }
        case .c(.struct):
            if let interfaceString = structs[name.name]?.semanticString(isStruct: true, isExpandHandler: isExpandHandler) {
                return .init(name: name, interfaceString: interfaceString)
            }
        case .c(.union):
            if let interfaceString = unions[name.name]?.semanticString(isStruct: false, isExpandHandler: isExpandHandler) {
                return .init(name: name, interfaceString: interfaceString)
            }
        default:
            break
        }
        throw Error.invalidRuntimeObjectName
    }

    func classHierarchy(for name: RuntimeObjectName) async throws -> [String] {
        guard case .objc(.type(.class)) = name.kind,
              let classGroups = classes[name.name]
        else { return [] }
        return classGroups.info.map(\.name)
    }
}

extension Set {
    @inlinable mutating func insert<S>(contentsOf newElements: S) where S : Sequence, Element == S.Element {
        for newElement in newElements {
            insert(newElement)
        }
    }
}
