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

typealias LoadingEventContinuation = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation

@Codable
@MemberInit
public struct ObjCGenerationOptions: Sendable, Equatable {
    @Default(false)
    public var stripProtocolConformance: Bool
    @Default(false)
    public var stripOverrides: Bool
    @Default(false)
    public var stripSynthesizedIvars: Bool
    @Default(false)
    public var stripSynthesizedMethods: Bool
    @Default(false)
    public var stripCtorMethod: Bool
    @Default(false)
    public var stripDtorMethod: Bool
    @Default(false)
    public var addIvarOffsetComments: Bool
    @Default(false)
    public var addPropertyAttributesComments: Bool
    @Default(false)
    public var addMethodIMPAddressComments: Bool
    @Default(false)
    public var addPropertyAccessorAddressComments: Bool
    
    public static let `default` = Self()
}

@Loggable(.private)
actor RuntimeObjCSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private let factory: RuntimeObjCSectionFactory

    /// Per-image Objective-C interface index: the parsed data store for
    /// this image (classes, protocols, categories, C struct/union
    /// definitions) plus the inheritance / protocol-adoption reverse
    /// tables. Constructed in `init` with this image's `MachOImage` and
    /// populated by `objcIndexer.prepare()`; afterwards this section only
    /// *reads* it back to translate into `RuntimeViewerCore` domain types
    /// (`RuntimeObject`, `RuntimeObjectInterface`, `RuntimeMemberAddress`).
    ///
    /// `nonisolated let` so `RuntimeRelationshipsResolver` and the factory's
    /// aggregate can read its query methods without an actor hop —
    /// `RuntimeObjCInterfaceIndexer` is `Sendable` and protects its own
    /// state with `@Mutex`.
    nonisolated let objcIndexer: RuntimeObjCInterfaceIndexer

    init(imagePath: String, factory: RuntimeObjCSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section for image: \(imagePath, privacy: .public)")
        guard let machO = DyldUtilities.machOImage(forPath: imagePath) else {
            #log(.error, "Failed to create MachOImage for: \(imagePath, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.machO = machO
        self.imagePath = imagePath
        self.factory = factory
        self.objcIndexer = RuntimeObjCInterfaceIndexer(machO: machO, imagePath: imagePath)
        try await objcIndexer.prepare(progressContinuation: progressContinuation)
    }

    init(machO: MachOImage, factory: RuntimeObjCSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section from MachO: \(machO.imagePath, privacy: .public)")
        self.machO = machO
        self.imagePath = machO.imagePath
        self.factory = factory
        self.objcIndexer = RuntimeObjCInterfaceIndexer(machO: machO, imagePath: machO.imagePath)
        try await objcIndexer.prepare(progressContinuation: progressContinuation)
    }

    func allObjects() async throws -> [RuntimeObject] {
        #log(.debug, "Getting all ObjC objects")
        var results: [RuntimeObject] = []

        for structName in objcIndexer.structNames {
            results.append(.init(name: structName, displayName: structName, kind: .c(.struct), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for unionName in objcIndexer.unionNames {
            results.append(.init(name: unionName, displayName: unionName, kind: .c(.union), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for className in objcIndexer.classNames {
            let isSwiftStable = objcIndexer.classGroup(forName: className)?.objcClass.isSwiftStable ?? false
            results.append(.init(name: className, displayName: className, kind: .objc(.type(.class)), secondaryKind: isSwiftStable ? .swift(.type(.class)) : nil, imagePath: imagePath, children: []))
        }

        for proto in objcIndexer.protocolNames {
            results.append(.init(name: proto, displayName: proto, kind: .objc(.type(.protocol)), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        for category in objcIndexer.categoryNames {
            results.append(.init(name: category, displayName: category, kind: .objc(.category(.class)), secondaryKind: nil, imagePath: imagePath, children: []))
        }

        #log(.debug, "Found \(results.count, privacy: .public) ObjC objects")
        return results
    }

    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration) async throws -> RuntimeObjectInterface {
        #log(.debug, "Generating interface for: \(object.name, privacy: .public)")
        let name = object.withImagePath(imagePath)
        let cTypeReplacements = transformer.cType.isEnabled ? transformer.cType.replacements : [:]
        let ivarOffsetTransformer = transformer.ivarOffset.isEnabled ? transformer.ivarOffset : nil
        let objcDumpContext = ObjCDumpContext(machO: machO, options: options, cTypeReplacements: cTypeReplacements) { name, isStruct in
            guard let name else { return true }
            if isStruct {
                return !self.objcIndexer.containsStruct(named: name)
            } else {
                return !self.objcIndexer.containsUnion(named: name)
            }
        }
        objcDumpContext.ivarOffsetTransformer = ivarOffsetTransformer

        switch name.kind {
        case .objc(.type(.class)):
            if let classGroup = objcIndexer.classGroup(forName: name.name), let currentClassInfo = classGroup.info.first {
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
                    if options.addPropertyAccessorAddressComments {
                        for method in currentClassInfo.methods where method.imp != 0 {
                            objcDumpContext.methodIMPs[method.name] = method.imp
                        }
                        for method in currentClassInfo.classMethods where method.imp != 0 {
                            objcDumpContext.classMethodIMPs[method.name] = method.imp
                        }
                    }
                    return .init(object: name, interfaceString: finalClassInfo.semanticString(using: objcDumpContext))
                }
            }
        case .objc(.type(.protocol)):
            if let currentProtocolInfo = objcIndexer.protocolGroup(forName: name.name)?.info {
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
            if let categoryInfo = objcIndexer.categoryGroup(forName: name.name)?.info {
                if options.addPropertyAccessorAddressComments {
                    for method in categoryInfo.methods where method.imp != 0 {
                        objcDumpContext.methodIMPs[method.name] = method.imp
                    }
                    for method in categoryInfo.classMethods where method.imp != 0 {
                        objcDumpContext.classMethodIMPs[method.name] = method.imp
                    }
                }
                return .init(object: name, interfaceString: categoryInfo.semanticString(using: objcDumpContext))
            }
        case .c(.struct):
            if let interfaceString = objcIndexer.structSemanticString(forName: name.name, context: objcDumpContext) {
                return .init(object: name, interfaceString: interfaceString)
            }
        case .c(.union):
            if let interfaceString = objcIndexer.unionSemanticString(forName: name.name, context: objcDumpContext) {
                return .init(object: name, interfaceString: interfaceString)
            }
        default:
            break
        }
        #log(.default, "Invalid runtime object: \(object.name, privacy: .public) kind: \(String(describing: object.kind), privacy: .public)")
        throw Error.invalidRuntimeObject
    }

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        #log(.debug, "Getting member addresses for: \(object.name, privacy: .public)")

        func shouldInclude(_ name: String) -> Bool {
            guard let filter = memberName else { return true }
            return name.lowercased().contains(filter.lowercased())
        }

        func formatAddress(_ imp: UInt64) -> String {
            machO.formattedAddressString(forRawValue: imp)
        }

        func collectMethods(_ methods: [ObjCMethodInfo], typeName: String) -> [RuntimeMemberAddress] {
            var result: [RuntimeMemberAddress] = []
            for method in methods {
                guard method.imp != 0, shouldInclude(method.name) else { continue }
                let prefix = method.isClassMethod ? "+" : "-"
                result.append(
                    RuntimeMemberAddress(
                        name: method.name,
                        kind: method.isClassMethod ? "class method" : "method",
                        symbolName: "\(prefix)[\(typeName) \(method.name)]",
                        address: formatAddress(method.imp)
                    )
                )
            }
            return result
        }

        func collectPropertyAccessors(
            properties: [ObjCPropertyInfo],
            methods: [ObjCMethodInfo],
            typeName: String
        ) -> [RuntimeMemberAddress] {
            // Build method name -> IMP lookup table
            var methodIMPs: [String: UInt64] = [:]
            for method in methods where method.imp != 0 {
                methodIMPs[method.name] = method.imp
            }

            var result: [RuntimeMemberAddress] = []
            for property in properties {
                let getterName = property.customGetter ?? property.name
                let setterName = property.customSetter ?? "set\(property.name.uppercasedFirst):"
                let prefix = property.isClassProperty ? "+" : "-"

                if let getterIMP = methodIMPs[getterName], shouldInclude(property.name) {
                    result.append(
                        RuntimeMemberAddress(
                            name: property.name,
                            kind: property.isClassProperty ? "class property getter" : "property getter",
                            symbolName: "\(prefix)[\(typeName) \(getterName)]",
                            address: formatAddress(getterIMP)
                        )
                    )
                }

                if let setterIMP = methodIMPs[setterName], shouldInclude(property.name) {
                    result.append(
                        RuntimeMemberAddress(
                            name: property.name,
                            kind: property.isClassProperty ? "class property setter" : "property setter",
                            symbolName: "\(prefix)[\(typeName) \(setterName)]",
                            address: formatAddress(setterIMP)
                        )
                    )
                }
            }
            return result
        }

        let name = object.withImagePath(imagePath)
        var result: [RuntimeMemberAddress] = []

        switch name.kind {
        case .objc(.type(.class)):
            if let classGroup = objcIndexer.classGroup(forName: name.name), let classInfo = classGroup.info.first {
                result.append(contentsOf: collectMethods(classInfo.methods + classInfo.classMethods, typeName: classInfo.name))
                result.append(contentsOf: collectPropertyAccessors(
                    properties: classInfo.properties + classInfo.classProperties,
                    methods: classInfo.methods + classInfo.classMethods,
                    typeName: classInfo.name
                ))
            }
        case .objc(.type(.protocol)):
            if let protocolInfo = objcIndexer.protocolGroup(forName: name.name)?.info {
                let allMethods = protocolInfo.methods + protocolInfo.classMethods + protocolInfo.optionalMethods + protocolInfo.optionalClassMethods
                result.append(contentsOf: collectMethods(allMethods, typeName: protocolInfo.name))
                result.append(contentsOf: collectPropertyAccessors(
                    properties: protocolInfo.properties + protocolInfo.classProperties + protocolInfo.optionalProperties + protocolInfo.optionalClassProperties,
                    methods: allMethods,
                    typeName: protocolInfo.name
                ))
            }
        case .objc(.category(.class)):
            if let categoryInfo = objcIndexer.categoryGroup(forName: name.name)?.info {
                result.append(contentsOf: collectMethods(categoryInfo.methods + categoryInfo.classMethods, typeName: categoryInfo.uniqueName))
                result.append(contentsOf: collectPropertyAccessors(
                    properties: categoryInfo.properties + categoryInfo.classProperties,
                    methods: categoryInfo.methods + categoryInfo.classMethods,
                    typeName: categoryInfo.uniqueName
                ))
            }
        default:
            break
        }

        #log(.debug, "Found \(result.count, privacy: .public) ObjC member addresses")
        return result
    }

    /// Materialize an Objective-C class `RuntimeObject` for a known class
    /// name within this image. Mirrors the shape `allObjects()` emits
    /// (including `secondaryKind == .swift(.type(.class))` for bridged
    /// classes), so relationship rows render identically to the sidebar's
    /// regular ObjC class entries. Returns `nil` when the class is not in
    /// this section.
    func makeRuntimeObject(forClassName className: String) -> RuntimeObject? {
        guard let classGroup = objcIndexer.classGroup(forName: className) else { return nil }
        return RuntimeObject(
            name: className,
            displayName: className,
            kind: .objc(.type(.class)),
            secondaryKind: classGroup.objcClass.isSwiftStable ? .swift(.type(.class)) : nil,
            imagePath: imagePath,
            children: []
        )
    }

    /// Materialize an Objective-C protocol `RuntimeObject`. Used by the
    /// engine to surface the *target* of an ObjC-protocol-conformers query.
    func makeRuntimeObject(forProtocolName protocolName: String) -> RuntimeObject? {
        guard objcIndexer.protocolGroup(forName: protocolName) != nil else { return nil }
        return RuntimeObject(
            name: protocolName,
            displayName: protocolName,
            kind: .objc(.type(.protocol)),
            secondaryKind: nil,
            imagePath: imagePath,
            children: []
        )
    }

    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        #log(.debug, "Getting class hierarchy for: \(object.name, privacy: .public)")
        guard case .objc(.type(.class)) = object.kind,
              let classGroups = objcIndexer.classGroup(forName: object.name)
        else {
            #log(.debug, "No class hierarchy found")
            return []
        }
        let hierarchy = classGroups.info.map(\.name)
        #log(.debug, "Class hierarchy: \(hierarchy.count, privacy: .public) levels")
        return hierarchy
    }
}

@Loggable(.private)
actor RuntimeObjCSectionFactory {
    private var sections: [String: RuntimeObjCSection] = [:]

    /// Aggregate Objective-C interface indexer. Each per-image
    /// `RuntimeObjCSection.objcIndexer` is registered as a sub-indexer when
    /// the section is created, so queries against this aggregate fan out
    /// across all loaded ObjC sections. Mirrors `RuntimeSwiftSectionFactory.indexer`.
    ///
    /// `RuntimeObjCInterfaceIndexer` binds a `MachOImage` at `init`; this
    /// aggregate never parses one of its own (`prepare()` is never called on
    /// it), so it is constructed against the current process image as a
    /// placeholder — mirroring `RuntimeSwiftSectionFactory`'s aggregate,
    /// which is likewise built `in: .current()`.
    let objcInterfaceIndexer: RuntimeObjCInterfaceIndexer
    
    init() {
        let currentMachO = MachOImage.current()
        objcInterfaceIndexer = RuntimeObjCInterfaceIndexer(machO: currentMachO, imagePath: currentMachO.imagePath)
    }

    func existingSection(for imagePath: String) -> RuntimeObjCSection? {
        sections[imagePath]
    }

    func hasCachedSection(for path: String) -> Bool {
        sections[path] != nil
    }

    /// Every image path with a cached `RuntimeObjCSection` — the canonical
    /// (dyld-patched) keys under which `section(for:)` registered them.
    /// `RuntimeRelationshipsResolver` intersects this with the Swift
    /// factory's set to obtain the indexed-image universe for a query, so
    /// it no longer needs the engine to thread `loadedImagePaths` in.
    var cachedImagePaths: Set<String> {
        Set(sections.keys)
    }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation? = nil) async throws -> (isExisted: Bool, section: RuntimeObjCSection) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached ObjC section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        #log(.debug, "Creating ObjC section for: \(imagePath, privacy: .public)")
        let section = try await RuntimeObjCSection(imagePath: imagePath, factory: self, progressContinuation: progressContinuation)
        sections[imagePath] = section
        objcInterfaceIndexer.addSubIndexer(section.objcIndexer)
        #log(.debug, "ObjC section created and cached")
        return (false, section)
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
            objcInterfaceIndexer.addSubIndexer(objcSection.objcIndexer)
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
