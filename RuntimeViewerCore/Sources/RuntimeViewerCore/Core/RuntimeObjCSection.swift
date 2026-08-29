import Foundation
import FoundationToolbox
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
private import RuntimeViewerObjC
import Semantic
import Utilities
import MetaCodable

/// `ObjCGenerationOptions`, the ObjC interface indexer and the whole
/// `ObjCDumpInfo → SemanticString` renderer now live library-side in
/// MachOObjCSection. This re-export keeps every existing
/// `ObjCGenerationOptions` reference in RuntimeViewer compiling unchanged.
@_exported import ObjCDeclarationRendering
@_exported import ObjCIndexing
import ObjCInterface

typealias LoadingEventContinuation = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation

@Loggable(.private)
actor RuntimeObjCSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private let factory: RuntimeObjCSectionFactory

    /// Per-image Objective-C interface index: the parsed data store for this
    /// image (classes, protocols, categories, C struct/union definitions) plus
    /// the inheritance and protocol-adoption reverse tables built alongside it.
    /// Constructed in `init` and populated by `objcIndexer.prepare()`;
    /// afterwards this section only *reads* it back to translate into
    /// `RuntimeViewerCore` domain types (`RuntimeObject`,
    /// `RuntimeObjectInterface`, `RuntimeMemberAddress`).
    ///
    /// The relationship tables live in here rather than in a separate object
    /// because that is what makes this the mirror image of
    /// `RuntimeSwiftSection.indexer` — see Evolution 0008.
    ///
    /// `nonisolated let` so `RuntimeRelationshipsResolver` can read its query
    /// methods without an actor hop — `RuntimeObjCInterfaceIndexer` is
    /// `Sendable` and protects its own state with its own locks.
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
        self.objcIndexer = RuntimeObjCInterfaceIndexer(
            machO: machO,
            imagePath: imagePath,
            progressContinuation: progressContinuation
        )
        try await objcIndexer.prepare()
    }

    init(machO: MachOImage, factory: RuntimeObjCSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section from MachO: \(machO.imagePath, privacy: .public)")
        self.machO = machO
        self.imagePath = machO.imagePath
        self.factory = factory
        self.objcIndexer = RuntimeObjCInterfaceIndexer(
            machO: machO,
            imagePath: machO.imagePath,
            progressContinuation: progressContinuation
        )
        try await objcIndexer.prepare()
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

        // The strip switches, the C-type substitution and the rendering all
        // live in MachOObjCSection's `ObjCInterface`; this section only maps
        // RuntimeViewer's `Transformer` settings onto that API and wraps the
        // result back into a `RuntimeObjectInterface`.
        // `ObjCInterfaceBuilder` consumes the library's indexer, so it takes
        // `upstream` rather than the wrapper. Mirrors `RuntimeSwiftSection`
        // handing `indexer.upstream` to `GenericSpecializer`.
        let builder = ObjCInterfaceBuilder(indexer: objcIndexer.upstream, machO: machO)
        let cTypeReplacements = transformer.cType.isEnabled
            ? transformer.cType.replacements.reduce(into: [ObjCPrimitiveTypePattern: String]()) { result, pair in
                guard let pattern = ObjCPrimitiveTypePattern(rawValue: pair.key.rawValue) else { return }
                result[pattern] = pair.value
            }
            : [:]
        let ivarOffsetCommentBuilder: (@Sendable (Int) -> String)?
        if transformer.ivarOffset.isEnabled {
            let module = transformer.ivarOffset
            ivarOffsetCommentBuilder = { offset in module.transform(.init(offset: offset)) }
        } else {
            ivarOffsetCommentBuilder = nil
        }

        let interfaceString: SemanticString?
        switch name.kind {
        case .objc(.type(.class)):
            interfaceString = builder.classInterface(
                named: name.name,
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        case .objc(.type(.protocol)):
            interfaceString = builder.protocolInterface(
                named: name.name,
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        case .objc(.category(.class)):
            interfaceString = builder.categoryInterface(
                uniqueName: name.name,
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        case .c(.struct):
            interfaceString = builder.structInterface(
                named: name.name,
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        case .c(.union):
            interfaceString = builder.unionInterface(
                named: name.name,
                options: options,
                cTypeReplacements: cTypeReplacements,
                ivarOffsetCommentBuilder: ivarOffsetCommentBuilder
            )
        default:
            interfaceString = nil
        }

        if let interfaceString {
            return .init(object: name, interfaceString: interfaceString)
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
    /// Cross-image aggregate: every per-image indexer registers here, so a
    /// single relationship query spans all loaded images.
    ///
    /// Evolution 0007 removed this on the grounds that it was written but never
    /// read — which was true, and is why `RuntimeRelationshipsResolver` had to
    /// walk every image itself, paying an actor hop per image to ask each one a
    /// question that is almost always answered "nothing". 0008 restores it and
    /// points the resolver at it instead. Mirrors
    /// `RuntimeSwiftSectionFactory.indexer`.
    ///
    /// Never `prepare()`d: it parses no image of its own and exists purely to
    /// fan queries out across `subIndexers`. `.current()` is a placeholder image
    /// for the same reason it is on the Swift side.
    let indexer: RuntimeObjCInterfaceIndexer

    /// Per-image sections, keyed by the dyld-canonical image path.
    private var sections: [String: RuntimeObjCSection] = [:]

    init() {
        let machO = MachOImage.current()
        self.indexer = RuntimeObjCInterfaceIndexer(machO: machO, imagePath: machO.imagePath)
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
        indexer.addSubIndexer(section.objcIndexer)
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
            indexer.addSubIndexer(objcSection.objcIndexer)
            return objcSection
        } catch {
            #log(.error, "Failed to create ObjC section: \(error, privacy: .public)")
            return nil
        }
    }

    /// Drop an image's section, detaching its indexer from the aggregate first.
    ///
    /// The order matters and the detach is not optional: the aggregate outlives
    /// every section (it lives as long as the owning `RuntimeEngine`), so
    /// dropping the `sections` entry alone reclaims nothing — the image's whole
    /// parsed index stays reachable through `indexer.subIndexers`. This is the
    /// leak `feature/node-store-adoption`'s f41648a diagnosed on the Swift side;
    /// restoring the aggregate here without its inverse would reintroduce it.
    func removeSection(for imagePath: String) {
        guard let section = sections.removeValue(forKey: imagePath) else { return }
        indexer.removeSubIndexer(section.objcIndexer)
    }

    func removeAllSections() {
        for section in sections.values {
            indexer.removeSubIndexer(section.objcIndexer)
        }
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
