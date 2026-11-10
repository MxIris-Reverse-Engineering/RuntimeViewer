import Foundation
import FoundationToolbox
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
private import RuntimeViewerObjC
import Semantic
import SwiftInspection
import SwiftObjCInterop
import Utilities
import MetaCodable

/// `ObjCGenerationOptions`, the ObjC interface indexer and the whole
/// `ObjCDumpInfo → SemanticString` renderer now live library-side in
/// MachOObjCSection. This re-export keeps every existing
/// `ObjCGenerationOptions` reference in RuntimeViewer compiling unchanged.
@_exported import ObjCDeclarationRendering
@_exported import ObjCIndexing
import ObjCInterface

@Loggable(.private)
actor RuntimeObjCSection<Reading: RuntimeImageReading>: RuntimeObjCSectioning {
    typealias MachO = Reading.MachO
    enum Error: Swift.Error {
        case imageNotFound
        case invalidRuntimeObject
    }

    nonisolated let imagePath: String

    private let machO: MachO

    private let factory: RuntimeObjCSectionFactory<Reading>

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
    nonisolated let objcIndexer: RuntimeObjCInterfaceIndexer<Reading>

    /// Bare names of the classes this image implements through SE-0436's
    /// `@objc @implementation extension`. Such a class is a PURE Objective-C
    /// class — `objcIndexer` sees it and `isSwiftStable` is false for it — so
    /// nothing in the ObjC metadata alone tells it apart from a clang class.
    /// MachOSwiftSection joins the ObjC classlist with the image's Swift
    /// symbols to recognize it; both of this section's `RuntimeObject`
    /// factories read the answer from here so the sidebar and the Inspector's
    /// relationship rows agree.
    ///
    /// Lazy because the join costs a pass over the classlist: an image whose
    /// objects are never listed never pays for it. Both evidence tiers count,
    /// the inferred one included — a stripped image is exactly where this is
    /// worth having, and the ivar type encodings it reads (`?` or empty) are
    /// shapes clang never writes.
    private lazy var objcImplementationClassNames: Set<String> = Set(
        ObjCImplementationClasses.all(in: machO).map(\.className)
    )

    /// Runtime names of the protocols this image lists that were defined in
    /// Swift. Both of this section's protocol factories read the answer from
    /// here, for the same reason as `objcImplementationClassNames`, and it is
    /// lazy for the same reason: it costs a pass over the protocol list.
    private lazy var swiftDefinedProtocolNames: Set<String> = SwiftDefinedObjCProtocols.names(of: Reading.objcProtocolRecords(in: machO))

    /// `imagePath` is the key the factory caches the section under, which the
    /// image itself cannot be asked for: a file's `imagePath` is its install
    /// name, and dyld's spelling of a loaded image's can differ from the
    /// canonical one.
    init(imagePath: String, machO: MachO, factory: RuntimeObjCSectionFactory<Reading>, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section for image: \(imagePath, privacy: .public)")
        self.machO = machO
        self.imagePath = imagePath
        self.factory = factory
        self.objcIndexer = RuntimeObjCInterfaceIndexer<Reading>(
            machO: machO,
            imagePath: imagePath,
            progressContinuation: progressContinuation
        )
        try await objcIndexer.prepare()
    }

    func allObjects() async throws -> [RuntimeObject] {
        #log(.debug, "Getting all ObjC objects")
        var results: [RuntimeObject] = []

        for structName in objcIndexer.structNames {
            results.append(.init(name: structName, displayName: structName, kind: .c(.struct), imagePath: imagePath, children: []))
        }

        for unionName in objcIndexer.unionNames {
            results.append(.init(name: unionName, displayName: unionName, kind: .c(.union), imagePath: imagePath, children: []))
        }

        for className in objcIndexer.classNames {
            let isSwiftStable = objcIndexer.classGroup(forName: className)?.objcClass.isSwiftStable ?? false
            results.append(.init(
                name: className,
                displayName: className,
                kind: .objc(.type(.class)),
                imagePath: imagePath,
                children: [],
                properties: properties(forClassNamed: className, isSwiftStable: isSwiftStable)
            ))
        }

        for proto in objcIndexer.protocolNames {
            results.append(.init(
                name: proto,
                displayName: proto,
                kind: .objc(.type(.protocol)),
                imagePath: imagePath,
                children: [],
                properties: properties(forProtocolNamed: proto)
            ))
        }

        for category in objcIndexer.categoryNames {
            results.append(.init(name: category, displayName: category, kind: .objc(.category(.class)), imagePath: imagePath, children: []))
        }

        #log(.debug, "Found \(results.count, privacy: .public) ObjC objects")
        return results
    }

    /// With `marksCommentStructure` on, the builder also marks what each
    /// comment is, and the interface carries the structure separated from
    /// the print; the text is the same either way.
    func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration, marksCommentStructure: Bool) async throws -> RuntimeObjectInterface {
        #log(.debug, "Generating interface for: \(object.name, privacy: .public)")
        let name = object.withImagePath(imagePath)

        // The strip switches, the C-type substitution and the rendering all
        // live in MachOObjCSection's `ObjCInterface`; this section only maps
        // RuntimeViewer's `Transformer` settings onto that API and wraps the
        // result back into a `RuntimeObjectInterface`.
        // `ObjCInterfaceBuilder` consumes the library's indexer, so it takes
        // `upstream` rather than the wrapper. Mirrors `RuntimeSwiftSection`
        // handing `indexer.upstream` to `GenericSpecializer`.
        let builder = ObjCInterfaceBuilder(indexer: objcIndexer.upstream, machO: machO, marksCommentStructure: marksCommentStructure)
        let (cTypeReplacements, ivarOffsetCommentBuilder) = Self.builderInputs(for: transformer)

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
            if marksCommentStructure {
                return .init(object: name, markedInterfaceString: interfaceString.frozen(), interfaceLanguage: .objectiveC)
            }
            return .init(object: name, interfaceString: interfaceString, interfaceLanguage: .objectiveC)
        }

        #log(.default, "Invalid runtime object: \(object.name, privacy: .public) kind: \(String(describing: object.kind), privacy: .public)")
        throw Error.invalidRuntimeObject
    }

    /// The object's interface with everything any `ObjCGenerationOptions`
    /// could show, and what the switches decide marked with
    /// `VisibilityRegion`s — the Find corpus's form of it (see
    /// `corpusPrint(for:transformer:)`). Projected with some options, it reads
    /// as `interface(for:using:transformer:)` with them. C structs and unions
    /// have nothing to mark and print as usual. `nil` for an object this image
    /// does not have.
    nonisolated func markedInterface(for object: RuntimeObject, transformer: Transformer.ObjCConfiguration) -> SemanticString? {
        let name = object.withImagePath(imagePath)
        let builder = ObjCInterfaceBuilder(indexer: objcIndexer.upstream, machO: machO)
        let (cTypeReplacements, ivarOffsetCommentBuilder) = Self.builderInputs(for: transformer)
        switch name.kind {
        case .objc(.type(.class)):
            return builder.markedClassInterface(named: name.name, cTypeReplacements: cTypeReplacements, ivarOffsetCommentBuilder: ivarOffsetCommentBuilder)
        case .objc(.type(.protocol)):
            return builder.markedProtocolInterface(named: name.name, cTypeReplacements: cTypeReplacements, ivarOffsetCommentBuilder: ivarOffsetCommentBuilder)
        case .objc(.category(.class)):
            return builder.markedCategoryInterface(uniqueName: name.name, cTypeReplacements: cTypeReplacements, ivarOffsetCommentBuilder: ivarOffsetCommentBuilder)
        case .c(.struct):
            return builder.structInterface(named: name.name, cTypeReplacements: cTypeReplacements, ivarOffsetCommentBuilder: ivarOffsetCommentBuilder)
        case .c(.union):
            return builder.unionInterface(named: name.name, cTypeReplacements: cTypeReplacements, ivarOffsetCommentBuilder: ivarOffsetCommentBuilder)
        default:
            return nil
        }
    }

    /// What `ObjCInterfaceBuilder` takes from RuntimeViewer's transformer
    /// settings: the C type spellings and the ivar offset comment.
    private static func builderInputs(for transformer: Transformer.ObjCConfiguration) -> (cTypeReplacements: [ObjCPrimitiveTypePattern: String], ivarOffsetCommentBuilder: (@Sendable (Int) -> String)?) {
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
        return (cTypeReplacements, ivarOffsetCommentBuilder)
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
            // Two tables, not one. An instance method and a class method may
            // share a selector — `-[NSObject description]` and
            // `+[NSObject description]` both exist — so a single table keyed by
            // name alone lets whichever is inserted last win, and an instance
            // property's getter then reports the class method's address while
            // still printing the instance method's symbol. MachOObjCSection's
            // rendering context splits them the same way, which is why the
            // interface text was right about a property the member list got
            // wrong. Split by the metadata's own flag rather than by the order
            // the caller concatenated its arrays in.
            var instanceMethodImplementations: [String: UInt64] = [:]
            var classMethodImplementations: [String: UInt64] = [:]
            for method in methods where method.imp != 0 {
                if method.isClassMethod {
                    classMethodImplementations[method.name] = method.imp
                } else {
                    instanceMethodImplementations[method.name] = method.imp
                }
            }

            var result: [RuntimeMemberAddress] = []
            for property in properties {
                let getterName = property.customGetter ?? property.name
                let setterName = property.customSetter ?? "set\(property.name.uppercasedFirst):"
                let prefix = property.isClassProperty ? "+" : "-"
                let methodIMPs = property.isClassProperty ? classMethodImplementations : instanceMethodImplementations

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
    /// (including `.isSwiftClass` for bridged classes), so relationship rows
    /// render identically to the sidebar's regular ObjC class entries.
    /// Returns `nil` when the class is not in this section.
    func makeRuntimeObject(forClassName className: String) -> RuntimeObject? {
        guard let classGroup = objcIndexer.classGroup(forName: className) else { return nil }
        return RuntimeObject(
            name: className,
            displayName: className,
            kind: .objc(.type(.class)),
            imagePath: imagePath,
            children: [],
            properties: properties(forClassNamed: className, isSwiftStable: classGroup.objcClass.isSwiftStable)
        )
    }

    /// The two ways an ObjC class can turn out to be Swift underneath are
    /// mutually exclusive: a bridged Swift class has the Swift bit set in its
    /// class data pointer, an `@objc @implementation` one has it clear. So a
    /// class that is already `isSwiftStable` is never looked up in the
    /// `@implementation` index.
    ///
    /// `isNotExported` comes from MachOObjCSection's verdict on the class
    /// object, the same for a bridged Swift class, whose Swift face the Swift
    /// section marks from its own descriptor verdict.
    private func properties(forClassNamed className: String, isSwiftStable: Bool) -> RuntimeObject.Properties {
        var properties: RuntimeObject.Properties
        if isSwiftStable {
            properties = [.isSwiftClass]
        } else {
            properties = objcImplementationClassNames.contains(className) ? [.isObjCImplementation] : []
        }
        if objcIndexer.isClassDefinitelyNotExported(named: className) {
            properties.insert(.isNotExported)
        }
        return properties
    }

    /// Materialize an Objective-C protocol `RuntimeObject`. Used by the
    /// engine to surface the *target* of an ObjC-protocol-conformers query.
    /// Mirrors the shape `allObjects()` emits, `.isSwiftProtocol` included.
    func makeRuntimeObject(forProtocolName protocolName: String) -> RuntimeObject? {
        guard objcIndexer.protocolGroup(forName: protocolName) != nil else { return nil }
        return RuntimeObject(
            name: protocolName,
            displayName: protocolName,
            kind: .objc(.type(.protocol)),
            imagePath: imagePath,
            children: [],
            properties: properties(forProtocolNamed: protocolName)
        )
    }

    private func properties(forProtocolNamed protocolName: String) -> RuntimeObject.Properties {
        swiftDefinedProtocolNames.contains(protocolName) ? [.isSwiftProtocol] : []
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
