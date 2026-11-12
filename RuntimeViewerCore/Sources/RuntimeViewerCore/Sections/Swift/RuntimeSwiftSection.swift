@_spi(Support) import SwiftDeclaration
@_spi(Support) import SwiftDeclarationRendering
@_spi(Support) import SwiftIndexing
@_spi(Support) import SwiftSpecialization
@_spi(Support) import SwiftPrinting
@_spi(Support) import SwiftInterface
@_spi(Support) import SwiftPrivateDiscriminators
@_spi(Internals) import SwiftInspection
import Demangling
import Foundation
import FoundationToolbox
import FrameworkToolbox
import MachOKit
import MachODependencies
import MachOObjCSection
import MachOSwiftSection
import OrderedCollections
import Semantic
import MetaCodable

@Loggable(.private)
actor RuntimeSwiftSection<Reading: RuntimeImageReading>: RuntimeSwiftSectioning {
    typealias MachO = Reading.MachO
    enum Error: Swift.Error {
        case imageNotFound
        case invalidRuntimeObject
    }

    nonisolated let imagePath: String

    private let machO: MachO

    private let factory: RuntimeSwiftSectionFactory<Reading>

    /// The index configuration of every Swift indexer RuntimeViewer creates —
    /// each section's own and the factory's aggregate.
    ///
    /// Fixed for the indexer's lifetime: `allObjects()`, the object-to-definition
    /// map and the relationship tables are all built once from what the indexer
    /// found, so changing what it indexes afterwards strands them. Applying a
    /// different configuration at interface time once emptied the map, and every
    /// Swift object then failed with `invalidRuntimeObject`.
    static func indexConfiguration(dependencySearchPaths: [DependencySearchPath]) -> SwiftDeclarationIndexConfiguration {
        var configuration = SwiftDeclarationIndexConfiguration(showCImportedTypes: true)
        configuration.dependencySearchPaths = dependencySearchPaths
        return configuration
    }

    /// Per-image Swift interface index — the Swift counterpart of
    /// `RuntimeObjCSection.objcIndexer`. Interface generation reads
    /// upstream-indexer properties (`allTypeDefinitions`, `rootTypeDefinitions`,
    /// …) straight off it via `RuntimeSwiftInterfaceIndexer`'s
    /// `@dynamicMemberLookup`; relationship indexing is encapsulated inside it.
    ///
    /// `nonisolated let` so `RuntimeRelationshipsResolver` can call its query
    /// methods without an actor hop — `RuntimeSwiftInterfaceIndexer` is
    /// `Sendable` and guards its own state.
    nonisolated let indexer: RuntimeSwiftInterfaceIndexer<Reading>

    /// The source files of this image's private discriminators, recovered from
    /// candidates the image's own names make and remembered per discriminator.
    /// `nonisolated let` so a search, which can run for seconds, holds no actor:
    /// the index guards its own state.
    private nonisolated let privateDiscriminatorSourceFileIndex: PrivateDiscriminatorSourceFileIndex

    private let printer: SwiftDeclarationPrinter<MachO>

    /// The printer the corpus is built with: marking optional content (so
    /// one print serves every combination of the Generation Options) with
    /// the user's transformer. A second instance
    /// rather than a reconfiguration of `printer`, because a print suspends
    /// mid-way and the display path may reconfigure `printer` in between —
    /// and because this one never touches `interfaceByObject`. Rebuilt when
    /// the transformer changes; see `corpusPrinter(for:)`.
    private var corpusPrinter: SwiftDeclarationPrinter<MachO>?

    private var corpusPrinterTransformer: Transformer.SwiftConfiguration?

    /// Keyed by `RuntimeObjectKey` (identity without `children`) so the
    /// sidebar's `parent.withAppendedChild(child)` replacement after a
    /// user-driven specialization doesn't invalidate the cached parent
    /// mapping — otherwise the next click on the parent generic would miss
    /// both maps and throw `invalidRuntimeObject`.
    private var interfaceByObject: OrderedDictionary<RuntimeObjectKey, RuntimeObjectInterface> = [:]

    /// The Objective-C objects of this image as Swift imports them
    /// (`importedInterface(for:)`), by the Objective-C object's key. Kept
    /// apart from `interfaceByObject`, whose keys are this image's Swift
    /// objects, and cleared with it when the print configuration changes.
    private var importedInterfaceByObject: [RuntimeObjectKey: RuntimeObjectInterface] = [:]

    private var specializedDefinitionByObject: [RuntimeObjectKey: TypeDefinition] = [:]

    private var lastTransformerConfiguration: Transformer.SwiftConfiguration = .init()

    /// Whether `printer` holds the opaque type resolver; see
    /// `updateConfiguration(using:transformer:marksCommentStructure:)`.
    private var isOpaqueTypeResolverRegistered = false

    /// How many times `updateConfiguration` has handed `printer` a new
    /// configuration, and registered the opaque type resolver with it. Read
    /// by tests: an update that changes nothing does neither.
    private(set) var printerConfigurationUpdateCount = 0

    private(set) var opaqueTypeResolverRegistrationCount = 0

    private var interfaceDefinitionNameByObject: [RuntimeObjectKey: InterfaceDefinitionName] = [:]

    /// Every Swift class this image registers with the Objective-C runtime,
    /// paired with its Objective-C runtime name both ways round. One table
    /// answers the `isObjCClass` mark, the jump between a class's two faces
    /// and the Inspector's rows for bridged subclasses; `makeObjCClassPairs()`
    /// says how a class is matched to its Swift type.
    ///
    /// Lazy, but `allObjects()` reads it while `init` runs — after
    /// `indexer.prepare()`, whose type definitions it is matched against.
    private lazy var objcClassPairs: ObjCClassPairs = makeObjCClassPairs()

    /// The `@objc @implementation` extensions `allObjects()` listed, by the
    /// Objective-C class each one implements, and the way back.
    private var objcImplementationExtensionObjectByClassName: [String: RuntimeObject] = [:]

    private var objcImplementationClassNameByExtensionMangledName: [String: String] = [:]

    /// The Objective-C protocols this image's extensions of other modules'
    /// classes adopt, filed under the extended class's extension name: the
    /// key its conformance extensions are filed under too, so an entry
    /// prints both. The compiler records these in categories, and no
    /// conformance record names them, because an Objective-C protocol has no
    /// witness table.
    private lazy var objcCategoryConformancesByExtensionName: OrderedDictionary<SwiftDeclaration.ExtensionName, [ObjCCategoryConformance]> = {
        var conformancesByExtensionName: OrderedDictionary<SwiftDeclaration.ExtensionName, [ObjCCategoryConformance]> = [:]
        for conformance in indexer.objcCategoryConformances {
            conformancesByExtensionName[conformance.extendedTypeName.extensionName, default: []].append(conformance)
        }
        return conformancesByExtensionName
    }()

    private struct ObjCClassPairs {
        var objcClassNameByMangledTypeName: [String: String] = [:]
        var mangledTypeNameByObjCClassName: [String: String] = [:]
    }

    /// Every `@objc` protocol this image declares in Swift that
    /// MachOSwiftSection paired with the image's Objective-C record of it,
    /// with the record's runtime name, both ways round. One table answers the
    /// `isObjCProtocol` mark and the jump between a protocol's two faces.
    ///
    /// Lazy, but `allObjects()` reads it while `init` runs — after
    /// `indexer.prepare()`, which lists the protocols.
    private lazy var objcProtocolPairs: ObjCProtocolPairs = makeObjCProtocolPairs()

    private struct ObjCProtocolPairs {
        var objcProtocolNameByMangledProtocolName: [String: String] = [:]
        var mangledProtocolNameByObjCProtocolName: [String: String] = [:]
    }

    private enum InterfaceDefinitionName {
        case rootType(SwiftDeclaration.TypeName)
        case childType(SwiftDeclaration.TypeName)
        /// Specialized children: each carries the unspecialized parent's
        /// `TypeName` (the lookup key into `indexer.allTypeDefinitions`)
        /// alongside the bound `TypeName` produced by
        /// `TypeDefinition.boundGenericTypeName(...)` (used to disambiguate
        /// inside the parent's `specializedChildren` array, since
        /// specialized definitions live on the parent rather than on the
        /// indexer).
        case specializedType(unspecialized: SwiftDeclaration.TypeName, specialized: SwiftDeclaration.TypeName)
        /// Nested specialized types derived by upstream's
        /// `derivingNestedSpecializationsWith` — e.g. when specializing
        /// `Phase<Event>`, upstream walks the parent's `typeChildren` and
        /// produces a `Phase<Event>.Value` that is itself specialized but
        /// has no generic parent the indexer knows about (the unspecialized
        /// `Phase.Value` lives under the unspecialized `Phase`, not under
        /// this derived `Phase<Event>`). Its `TypeDefinition` is only
        /// reachable through `specializedDefinitionByObject`; consumers
        /// MUST route through that cache rather than trying to look up the
        /// typeName in `indexer.allTypeDefinitions`.
        case derivedSpecializedType(SwiftDeclaration.TypeName)
        case rootProtocol(SwiftDeclaration.ProtocolName)
        case childProtocol(SwiftDeclaration.ProtocolName)
        /// An `@objc` protocol declared in Swift. The compiler gives it no
        /// protocol descriptor, so it is no `ProtocolDefinition`:
        /// MachOSwiftSection lists it in `objcProtocolDefinitions`.
        case objcProtocol(SwiftDeclaration.ProtocolName)
        case typeExtension(SwiftDeclaration.ExtensionName)
        case protocolExtension(SwiftDeclaration.ExtensionName)
        case typeAliasExtension(SwiftDeclaration.ExtensionName)
        case conformance(SwiftDeclaration.ExtensionName)

        var typeName: SwiftDeclaration.TypeName? {
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

    /// `imagePath` is the key the factory caches the section under; see
    /// `RuntimeObjCSection.init`.
    init(imagePath: String, machO: MachO, factory: RuntimeSwiftSectionFactory<Reading>, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing Swift section for image: \(imagePath, privacy: .public)")
        self.factory = factory
        self.imagePath = imagePath
        self.machO = machO
        #log(.debug, "Creating Swift Interface Components")
        let eventHandlers: [SwiftIndexEvents.Handler] = progressContinuation.map { [ProgressEventHandler(continuation: $0)] } ?? []
        let indexer = RuntimeSwiftInterfaceIndexer<Reading>(machO: machO, imagePath: imagePath, configuration: factory.indexConfiguration(forImageAt: imagePath), eventHandlers: eventHandlers)
        self.indexer = indexer
        // Reads the indexer's names on its first request, long after `prepare()`.
        self.privateDiscriminatorSourceFileIndex = Reading.makePrivateDiscriminatorSourceFileIndex(indexer: indexer.upstream)
        self.printer = .init(configuration: .init(), eventHandlers: [], in: machO)
        // `prepare()` runs the upstream extraction and then builds the
        // relationship reverse tables — that work now lives in
        // `RuntimeSwiftInterfaceIndexer`, not inline here.
        try await indexer.prepare(progressContinuation: progressContinuation)
        Self.installExportFilterScope(on: printer, from: indexer)
        _ = try await allObjects()
        #log(.info, "Swift section initialized successfully")
    }

    // MARK: - Object Enumeration

    private var allObjectsCache: [RuntimeObject]?

    func allObjects() async throws -> [RuntimeObject] {
        if let allObjectsCache {
            return allObjectsCache
        }
        #log(.debug, "Getting all Swift objects")
        let rootTypeName = try indexer.rootTypeDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let rootProtocolName = try indexer.rootProtocolDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let objcProtocolName = try indexer.objcProtocolDefinitions.values.map { try makeRuntimeObject(for: $0) }
        // An `@objc` protocol's extensions print with it, as a Swift
        // protocol's do: MachOSwiftSection attaches them to its definition.
        let objcProtocolExtensionNames = Set(indexer.objcProtocolDefinitions.keys.map(\.extensionName))
        let typeExtensionName = try indexer.typeExtensionDefinitions.filter { $0.key.typeName.map { indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeExtension($0.key)) }
        let protocolExtensionName = try indexer.protocolExtensionDefinitions.filter { ($0.key.protocolName.map { indexer.allProtocolDefinitions[$0] == nil } ?? false) && !objcProtocolExtensionNames.contains($0.key) }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .protocolExtension($0.key)) }
        let typeAliasExtensionName = try indexer.typeAliasExtensionDefinitions.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeAliasExtension($0.key)) }
        let conformanceExtensionName = try indexer.conformanceExtensionDefinitions.filter { $0.key.typeName.map { indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftConformance, definitionName: .conformance($0.key)) }
        // A class whose only conformances here are Objective-C ones gets an
        // entry of its own; one with conformance extensions prints them in
        // that entry (`printedDefinitions(for:)`).
        let objcCategoryConformanceName = try objcCategoryConformancesByExtensionName.keys.filter { extensionName in
            indexer.conformanceExtensionDefinitions[extensionName] == nil && (extensionName.typeName.map { indexer.allTypeDefinitions[$0] == nil } ?? true)
        }.map { try makeRuntimeObject(for: [], extensionName: $0, kind: $0.runtimeObjectKindOfSwiftConformance, definitionName: .conformance($0)) }
        let allObjects = rootTypeName + rootProtocolName + objcProtocolName + typeExtensionName + protocolExtensionName + typeAliasExtensionName + conformanceExtensionName + objcCategoryConformanceName
        #log(.debug, "Found \(allObjects.count, privacy: .public) Swift objects: \(rootTypeName.count, privacy: .public) types, \(rootProtocolName.count, privacy: .public) protocols, \(typeExtensionName.count, privacy: .public) type extensions")
        allObjectsCache = allObjects
        return allObjects
    }

    private func makeRuntimeObject(for extensionDefintions: [ExtensionDefinition], extensionName: ExtensionName, kind: RuntimeObjectKind, definitionName: InterfaceDefinitionName) throws -> RuntimeObject {
        let typeChildren = try extensionDefintions.flatMap(\.types).map { try makeRuntimeObject(for: $0, isChild: true) }
        let protocolChildren = try extensionDefintions.flatMap(\.protocols).map { try makeRuntimeObject(for: $0, isChild: true) }
        let mangledName = try mangleAsString(extensionName.node)
        // An `@objc @implementation extension` is the Swift face of the
        // Objective-C class it implements; MachOSwiftSection records which.
        let objcImplementationClassName = extensionDefintions.lazy.compactMap { $0.objcImplementation?.className }.first
        let runtimeObjectName = RuntimeObject(
            name: mangledName,
            displayName: extensionName.runtimeObjectDisplayName,
            kind: kind,
            imagePath: imagePath,
            children: typeChildren + protocolChildren,
            properties: objcImplementationClassName == nil ? [] : [.isObjCImplementation],
            privateDeclarations: extensionName.privateDeclarations
        )
        interfaceDefinitionNameByObject[runtimeObjectName.key] = definitionName
        if let objcImplementationClassName {
            objcImplementationExtensionObjectByClassName[objcImplementationClassName] = runtimeObjectName
            objcImplementationClassNameByExtensionMangledName[mangledName] = objcImplementationClassName
        }
        return runtimeObjectName
    }

    private func makeRuntimeObject(for protocolDefintion: ProtocolDefinition, isChild: Bool) throws -> RuntimeObject {
        let mangledName = try mangleAsString(protocolDefintion.protocolName.node)
        let properties = protocolDefintion.exportStatus.runtimeObjectProperties
        let runtimeObjectName: RuntimeObject
        if isChild {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.currentName, kind: protocolDefintion.protocolName.runtimeObjectKind, imagePath: imagePath, children: [], properties: properties, privateDeclarations: protocolDefintion.protocolName.privateDeclarations)
            interfaceDefinitionNameByObject[runtimeObjectName.key] = .childProtocol(protocolDefintion.protocolName)
        } else {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.name, kind: protocolDefintion.protocolName.runtimeObjectKind, imagePath: imagePath, children: [], properties: properties, privateDeclarations: protocolDefintion.protocolName.privateDeclarations)
            interfaceDefinitionNameByObject[runtimeObjectName.key] = .rootProtocol(protocolDefintion.protocolName)
        }
        return runtimeObjectName
    }

    /// An `@objc` protocol declared in Swift, listed with the image's Swift
    /// protocols and under the same rule for its name. One declared in a type
    /// is listed at the top level: MachOSwiftSection prints it in an
    /// extension of its parent, which reads the same wherever it is listed.
    ///
    /// Such a protocol has no symbol of its own, so MachOSwiftSection rules
    /// on it by its name alone: a private one, or one nested in a private
    /// type, is marked `isNotExported`, and any other carries no verdict.
    private func makeRuntimeObject(for objcProtocolDefinition: ObjCProtocolDefinition) throws -> RuntimeObject {
        let protocolName = objcProtocolDefinition.protocolName
        let mangledName = try mangleAsString(protocolName.node)
        var properties: RuntimeObject.Properties = objcProtocolPairs.objcProtocolNameByMangledProtocolName[mangledName] == nil ? [] : [.isObjCProtocol]
        properties.formUnion(objcProtocolDefinition.exportStatus.runtimeObjectProperties)
        let runtimeObject = RuntimeObject(
            name: mangledName,
            displayName: protocolName.name,
            kind: protocolName.runtimeObjectKind,
            imagePath: imagePath,
            children: [],
            properties: properties,
            privateDeclarations: protocolName.privateDeclarations
        )
        interfaceDefinitionNameByObject[runtimeObject.key] = .objcProtocol(protocolName)
        return runtimeObject
    }

    private func makeRuntimeObject(
        for typeDefinition: TypeDefinition,
        isChild: Bool,
        unspecializedTypeName: SwiftDeclaration.TypeName? = nil,
    ) throws -> RuntimeObject {
        let mangledName = try mangleAsString(typeDefinition.typeName.node)
        let typeChildren = try typeDefinition.typeChildren.map {
            try makeRuntimeObject(for: $0, isChild: true)
        }
        let protocolChildren = try typeDefinition.protocolChildren.map { try makeRuntimeObject(for: $0, isChild: true) }
        // Types and protocols this image declares in an extension of the type.
        // Their parent is an extension context, so upstream files them under
        // `typeExtensionDefinitions`, not `typeChildren`. An extension keyed by
        // this very type name extends it from another module without
        // constraints — in practice a C-imported type, whose descriptor lives in
        // this image — and `allObjects()` folds such an extension into the
        // type's entry instead of listing it, so these would otherwise appear
        // nowhere. A constrained extension is keyed by the bound generic type,
        // stays listed on its own and never reaches here.
        let extensionDefinitions = typeDefinition.isSpecialized ? [] : indexer.typeExtensionDefinitions[typeDefinition.typeName.extensionName] ?? []
        let childTypeNames = Set(typeDefinition.typeChildren.map(\.typeName))
        let extensionTypeChildren = try extensionDefinitions.flatMap(\.types)
            .filter { !childTypeNames.contains($0.typeName) }
            .map { try makeRuntimeObject(for: $0, isChild: true) }
        let extensionProtocolChildren = try extensionDefinitions.flatMap(\.protocols).map { try makeRuntimeObject(for: $0, isChild: true) }
        let specializedChildren = try typeDefinition.specializedChildren.map {
            try makeRuntimeObject(
                for: $0,
                isChild: true,
                unspecializedTypeName: typeDefinition.typeName,
            )
        }
        let allChildren = typeChildren + extensionTypeChildren + protocolChildren + extensionProtocolChildren + specializedChildren

        var properties: RuntimeObject.Properties = []
        if typeDefinition.typeContextDescriptorWrapper.contextDescriptor.layout.flags.isGeneric {
            properties.insert(.isGeneric)
        }
        let isSpecialized = typeDefinition.isSpecialized
        if isSpecialized {
            properties.insert(.isSpecialized)
        }
        if objcClassPairs.objcClassNameByMangledTypeName[mangledName] != nil {
            properties.insert(.isObjCClass)
        }
        properties.formUnion(typeDefinition.typeName.localTypeProperties)
        // A specialized definition carries the status of the generic type it
        // specializes, whose descriptor it shares.
        properties.formUnion(typeDefinition.exportStatus.runtimeObjectProperties)
        let displayName = isSpecialized ? typeDefinition.typeName.name(using: .interfaceTypeBuilderOnly.subtracting(.removeBoundGeneric)) : typeDefinition.typeName.runtimeObjectDisplayName

        let runtimeObject = RuntimeObject(
            name: mangledName,
            displayName: displayName,
            kind: typeDefinition.typeName.runtimeObjectKind,
            imagePath: imagePath,
            children: allChildren,
            properties: properties,
            privateDeclarations: typeDefinition.typeName.privateDeclarations,
        )
        if isSpecialized, let unspecializedTypeName {
            interfaceDefinitionNameByObject[runtimeObject.key] = .specializedType(unspecialized: unspecializedTypeName, specialized: typeDefinition.typeName)
            specializedDefinitionByObject[runtimeObject.key] = typeDefinition
        } else if isSpecialized {
            // Derived nested specialization: upstream produced this object
            // by walking a freshly specialized parent's `typeChildren` (see
            // `derivingNestedSpecializationsWith`) — its generic ancestor
            // lives elsewhere in the indexer and is not addressable from
            // here. The `TypeDefinition` is still authoritative, so cache
            // it directly and let consumers look it up through
            // `specializedDefinitionByObject` instead of the indexer.
            interfaceDefinitionNameByObject[runtimeObject.key] = .derivedSpecializedType(typeDefinition.typeName)
            specializedDefinitionByObject[runtimeObject.key] = typeDefinition
        } else if isChild {
            interfaceDefinitionNameByObject[runtimeObject.key] = .childType(typeDefinition.typeName)
        } else {
            interfaceDefinitionNameByObject[runtimeObject.key] = .rootType(typeDefinition.typeName)
        }
        return runtimeObject
    }

    func setupForFactory(_ factory: RuntimeSwiftSectionFactory<Reading>) {
        factory.indexer.addSubIndexer(indexer)
    }

    /// Tells `printer` which of this image's types and protocols are not
    /// exported, the one thing the exported-only filter cannot work out for
    /// an extension by itself: whether its target, or the protocol it conforms
    /// to, is one of them. `SwiftInterfaceBuilder.printRoot()` installs it;
    /// RuntimeViewer prints definition by definition, so each of its printers
    /// gets it here. Without it the filter keeps every extension, and a marked
    /// print marks none. Once per printer: the indexer's configuration, and so
    /// its tables, are fixed for its lifetime (`indexConfiguration`).
    private static func installExportFilterScope(on printer: SwiftDeclarationPrinter<MachO>, from indexer: RuntimeSwiftInterfaceIndexer<Reading>) {
        printer.installExportFilterScope(types: indexer.allTypeDefinitions.values, protocols: indexer.allProtocolDefinitions.values)
    }
}

extension RuntimeSwiftSection {
    func interface(for object: RuntimeObject) async throws -> RuntimeObjectInterface {
        #log(.debug, "Generating Swift interface for: \(object.displayName, privacy: .public)")
        if let interface = interfaceByObject[object.key] {
            #log(.debug, "Using cached interface")
            return interface
        }
        // Read before printing, as the configuration the print starts with.
        let marksCommentStructure = printer.configuration.marksCommentStructure
        let marksAttachedMacros = printer.configuration.marksAttachedMacros
        let definitions = try printedDefinitions(for: object)
        let definitionPrints = try await Self.printDefinitions(definitions, using: printer)
        let newInterfaceString = Self.joinedDefinitionPrints(definitionPrints)
        let separatedPrint = Self.separatingMarks(of: newInterfaceString, marksAttachedMacros: marksAttachedMacros,
                                                  marksCommentStructure: marksCommentStructure)
        var macroExpansions: [RuntimeInterfaceMacroExpansion]?
        if marksAttachedMacros, let annotations = separatedPrint.annotations {
            // The type's own print comes first, and joining puts nothing before it: its range ends
            // with the type's closing brace, which part of a macro's expansion goes by.
            let typeUTF8Range: Range<Int>? = if case .type? = definitions.first, let typePrint = definitionPrints.first, !typePrint.isEmpty {
                0 ..< typePrint.string.utf8.count
            } else {
                nil
            }
            macroExpansions = try await self.macroExpansions(
                of: object,
                text: separatedPrint.text,
                typeUTF8Range: typeUTF8Range,
                definitionRegions: separatedPrint.definitionRegions,
                annotations: annotations
            )
        }
        let newInterface = RuntimeObjectInterface(
            object: object,
            interfaceString: separatedPrint.text,
            commentStructure: marksCommentStructure ? separatedPrint.annotations.map(RuntimeInterfaceCommentStructure.init) : nil,
            interfaceLanguage: .swift,
            macroExpansions: macroExpansions
        )
        interfaceByObject[object.key] = newInterface
        #log(.debug, "Interface generated and cached")
        return newInterface
    }

    /// An Objective-C class, category or protocol of this image as Swift imports it — the
    /// Generated Interface. MachOSwiftSection names the members by the ClangImporter's rules and
    /// takes what Swift implements (a Swift class, an `@objc @implementation` class, a Swift
    /// extension) from this image's Swift definitions, which is why the Swift section prints it.
    /// `nil` for anything else, and for an object this image does not define.
    func importedInterface(for object: RuntimeObject) async throws -> RuntimeObjectInterface? {
        let object = object.withImagePath(imagePath)
        if let interface = importedInterfaceByObject[object.key] {
            return interface
        }
        // Read before printing, as the configuration the print starts with.
        let marksCommentStructure = printer.configuration.marksCommentStructure
        let marksAttachedMacros = printer.configuration.marksAttachedMacros
        let upstreamIndexer = indexer.upstream
        let interfaceString: SemanticString
        switch object.kind {
        case .objc(.type(.class)):
            guard let definition = upstreamIndexer.objcImportedClassDefinition(named: object.name) else { return nil }
            interfaceString = try await printer.printObjCImportedClassDefinition(definition)
        case .objc(.type(.protocol)):
            guard let definition = upstreamIndexer.objcImportedProtocolDefinition(named: object.name) else { return nil }
            interfaceString = try await printer.printObjCImportedProtocolDefinition(definition)
        case .objc(.category):
            guard let definition = upstreamIndexer.objcImportedCategoryDefinition(uniqueName: object.name) else { return nil }
            interfaceString = try await printer.printObjCImportedCategoryDefinition(definition)
        default:
            return nil
        }
        // The marks attached macros bring are taken out with the rest; an imported interface shows
        // no macro of its own to expand.
        let separatedPrint = Self.separatingMarks(of: interfaceString, marksAttachedMacros: marksAttachedMacros,
                                                  marksCommentStructure: marksCommentStructure)
        let interface = RuntimeObjectInterface(
            object: object,
            interfaceString: separatedPrint.text,
            commentStructure: marksCommentStructure ? separatedPrint.annotations.map(RuntimeInterfaceCommentStructure.init) : nil,
            interfaceLanguage: .swift
        )
        importedInterfaceByObject[object.key] = interface
        return interface
    }

    /// A display print's text, and the tables of the marks the printer was
    /// configured to put in it (`updateConfiguration`): the definition regions
    /// while attached macros are marked, the annotation regions — comments and
    /// attached macros' attributes — while either is. A table that was not
    /// asked for is nil. The text is what printing without the marks gives.
    private static func separatingMarks(of print: SemanticString, marksAttachedMacros: Bool, marksCommentStructure: Bool)
        -> (text: FrozenSemanticString, definitionRegions: DefinitionRegionTable?, annotations: AnnotationRegionTable?) {
        var text = print.frozen()
        var definitionRegions: DefinitionRegionTable?
        if marksAttachedMacros {
            let (unmarkedText, regions) = text.separatingDefinitionRegions()
            text = unmarkedText
            definitionRegions = regions
        }
        var annotations: AnnotationRegionTable?
        if marksAttachedMacros || marksCommentStructure {
            let (unmarkedText, regions) = text.separatingAnnotationRegions()
            text = unmarkedText
            annotations = regions
        }
        return (text, definitionRegions, annotations)
    }

    /// The macros attached to the definitions in `object`'s print, each with
    /// the declarations it generated in the places they go, in text order.
    ///
    /// MachOSwiftSection marks each attribute it prints with an annotation
    /// region of the macro's kind, each tracked property's declaration with
    /// one of a kind naming the property, and every type printed inside
    /// another with a definition region named after the type's mangled name:
    /// an attribute belongs to the innermost definition region around it, or
    /// to the type `object` prints when there is none, whose own print is
    /// `typeUTF8Range` of `text`. The types are looked up in the definitions
    /// printed, not in `object`'s children, which a caller may not have
    /// filled in. The parts are the printer's, under the configuration it
    /// printed the interface with, their marks taken out: a tracked
    /// property's goes below its declaration, the generated members above
    /// the type's closing brace — the last line of the type's range — and the
    /// generated conformance below it.
    private func macroExpansions(
        of object: RuntimeObject,
        text: FrozenSemanticString,
        typeUTF8Range: Range<Int>?,
        definitionRegions: DefinitionRegionTable?,
        annotations: AnnotationRegionTable
    ) async throws -> [RuntimeInterfaceMacroExpansion] {
        let attributeRegions = annotations.regions.filter { region in
            Self.knownAttachedMacros.contains { AnnotationRegion.Kind.attachedMacro($0) == region.kind }
        }
        guard !attributeRegions.isEmpty else { return [] }

        let definitions = try printedDefinitions(for: object)
        let printedType = definitions.lazy.compactMap { definition -> TypeDefinition? in
            if case .type(let typeDefinition) = definition { return typeDefinition }
            return nil
        }.first
        let nestedTypesByMangledName = Self.nestedTypeDefinitionsByMangledName(in: definitions)
        let regions = definitionRegions?.regions ?? []
        let utf8Text = Array(text.string.utf8)

        var expansions: [RuntimeInterfaceMacroExpansion] = []
        // A type carries one attribute of each macro. A second attributed to
        // the same type lies in a nested type that was printed without its
        // region, and whose expansion is therefore unknown: it gets none.
        var expandedOwners: Set<String> = []
        for attributeRegion in attributeRegions {
            guard let macro = Self.knownAttachedMacros.first(where: {
                AnnotationRegion.Kind.attachedMacro($0) == attributeRegion.kind
            }) else { continue }
            let attributeRange = Self.utf8Range(offset: attributeRegion.utf8Offset, length: attributeRegion.utf8Length)
            let ownerRegion = Self.innermostDefinitionRegion(around: attributeRange, in: regions)
            let owner = if let ownerRegion { nestedTypesByMangledName[ownerRegion.identity] } else { printedType }
            let ownerRange = ownerRegion.map { Self.utf8Range(offset: $0.utf8Offset, length: $0.utf8Length) } ?? typeUTF8Range
            let ownerIdentity = "\(ownerRegion?.identity ?? "")|\(attributeRegion.kind.rawValue)"
            guard let owner, let ownerRange, expandedOwners.insert(ownerIdentity).inserted else { continue }
            let closingBraceLine = Self.lastLineRange(of: ownerRange, in: utf8Text)

            var parts: [RuntimeInterfaceMacroExpansion.Part] = []
            for expansionPart in try await printer.printMacroExpansionParts(of: macro, attachedTo: owner) {
                let anchorRange: Range<Int>
                let placement: RuntimeInterfaceMacroExpansion.Part.Placement
                switch expansionPart.placement {
                case .trackedProperty:
                    // The declaration in the owner itself: a type nested in it can track a
                    // property of the same name, whose region has the same kind.
                    guard let anchorKind = expansionPart.anchorKind,
                          let declarationRegion = annotations.regions.first(where: { region in
                              let declarationRange = Self.utf8Range(offset: region.utf8Offset, length: region.utf8Length)
                              return region.kind == anchorKind
                                  && ownerRange.contains(declarationRange.lowerBound)
                                  && Self.innermostDefinitionRegion(around: declarationRange, in: regions)?.utf8Offset == ownerRegion?.utf8Offset
                          })
                    else { continue }
                    anchorRange = Self.utf8Range(offset: declarationRegion.utf8Offset, length: declarationRegion.utf8Length)
                    placement = .belowLine
                case .members:
                    anchorRange = closingBraceLine
                    placement = .aboveLine
                case .conformance:
                    anchorRange = closingBraceLine
                    placement = .belowLine
                }
                let content = Self.separatingMarks(of: expansionPart.content, marksAttachedMacros: true, marksCommentStructure: true).text
                guard !content.string.isEmpty else { continue }
                parts.append(RuntimeInterfaceMacroExpansion.Part(anchorUTF8Range: anchorRange, placement: placement, content: content))
            }
            guard !parts.isEmpty else { continue }
            expansions.append(RuntimeInterfaceMacroExpansion(
                macroName: String(attributeRegion.kind.rawValue.dropFirst("attachedMacro.".count)),
                attributeUTF8Range: attributeRange,
                parts: parts
            ))
        }
        return expansions
    }

    private static func utf8Range(offset: some BinaryInteger, length: some BinaryInteger) -> Range<Int> {
        Int(offset) ..< Int(offset) + Int(length)
    }

    /// The deepest definition region `range` lies in, if any: the type a
    /// piece of the print belongs to.
    private static func innermostDefinitionRegion(around range: Range<Int>, in regions: [DefinitionRegionTable.Region]) -> DefinitionRegionTable.Region? {
        regions
            .filter { region in
                let regionRange = utf8Range(offset: region.utf8Offset, length: region.utf8Length)
                return regionRange.lowerBound <= range.lowerBound && range.upperBound <= regionRange.upperBound
            }
            .max { $0.depth < $1.depth }
    }

    /// The last line of `range` in `utf8Text`, without the line break and
    /// trailing whitespace before its end: a definition's closing brace,
    /// indentation included.
    private static func lastLineRange(of range: Range<Int>, in utf8Text: [UInt8]) -> Range<Int> {
        var lineEnd = min(range.upperBound, utf8Text.count)
        while lineEnd > range.lowerBound, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n")].contains(utf8Text[lineEnd - 1]) {
            lineEnd -= 1
        }
        var lineStart = lineEnd
        while lineStart > range.lowerBound, utf8Text[lineStart - 1] != UInt8(ascii: "\n") {
            lineStart -= 1
        }
        return lineStart ..< lineEnd
    }

    /// The attached macros MachOSwiftSection recognizes. Computed: the section
    /// is generic, and a generic type stores no static property.
    private static var knownAttachedMacros: [SwiftAttachedMacro] { [.observable] }

    /// Every type printed inside `definitions` — nested in the type, or in one
    /// of its extensions, at any depth — by its mangled name, which is what
    /// MachOSwiftSection names a nested definition's region after, and what
    /// the sidebar names the type's object.
    private static func nestedTypeDefinitionsByMangledName(in definitions: [PrintedDefinition]) -> [String: TypeDefinition] {
        var typeDefinitionsByMangledName: [String: TypeDefinition] = [:]
        func visit(_ typeDefinition: TypeDefinition) {
            if let mangledName = try? mangleAsString(typeDefinition.typeName.node) {
                typeDefinitionsByMangledName[mangledName] = typeDefinition
            }
            typeDefinition.typeChildren.forEach(visit)
        }
        for definition in definitions {
            switch definition {
            case .type(let typeDefinition):
                typeDefinition.typeChildren.forEach(visit)
            case .extension(let extensionDefinition):
                extensionDefinition.types.forEach(visit)
            case .protocol, .objcProtocol, .objcCategoryConformance:
                break
            }
        }
        return typeDefinitionsByMangledName
    }

    /// One definition of an object's interface, in printing order.
    enum PrintedDefinition {
        case type(TypeDefinition)
        case `protocol`(ProtocolDefinition)
        case `extension`(ExtensionDefinition)
        /// Printed with its default implementations after it.
        case objcProtocol(ObjCProtocolDefinition)
        /// `extension Class: P {}`, from a category of this image.
        /// `isNotExported` when the exported-only filter leaves the
        /// conformance out: the class is a type of this image that is not
        /// exported, or every protocol the category adopts is an `@objc`
        /// protocol of this image that is not — a private one.
        case objcCategoryConformance(ObjCCategoryConformance, isNotExported: Bool)
    }

    /// The definitions an object's interface is printed from, in the order
    /// they are printed: the type or protocol itself first, then its
    /// extensions. Shared by the display path, the corpus path and the
    /// member listing, so the three cannot disagree about what an object is.
    func printedDefinitions(for object: RuntimeObject) throws -> [PrintedDefinition] {
        guard let interfaceDefinitionName = interfaceDefinitionNameByObject[object.key] else {
            #log(.default, "Invalid runtime object: \(object.displayName, privacy: .public)")
            throw Error.invalidRuntimeObject
        }
        switch interfaceDefinitionName {
        case .specializedType(let unspecializedTypeName, let specializedTypeName):
            if let specializedDefinition = specializedDefinitionByObject[object.key] {
                return [.type(specializedDefinition)]
            }
            // The indexer keeps `allTypeDefinitions` keyed by the
            // unspecialized typeName; specialized children live on the
            // parent's `specializedChildren` array (per the upstream's
            // intentional decision to keep the indexer agnostic of
            // user-driven specialization). Look up the parent first, then
            // pick the specialized sibling whose bound `TypeName` matches.
            guard let parentDefinition = indexer.allTypeDefinitions[unspecializedTypeName],
                  let specializedDefinition = parentDefinition.specializedChildren.first(where: { $0.typeName == specializedTypeName })
            else { throw Error.invalidRuntimeObject }
            return [.type(specializedDefinition)]
        case .derivedSpecializedType:
            guard let specializedDefinition = specializedDefinitionByObject[object.key] else {
                throw Error.invalidRuntimeObject
            }
            return [.type(specializedDefinition)]
        case .rootType(let rootTypeName):
            guard let typeDefinition = indexer.rootTypeDefinitions[rootTypeName] else { throw Error.invalidRuntimeObject }
            return [.type(typeDefinition)]
                + (indexer.typeExtensionDefinitions[rootTypeName.extensionName] ?? []).map(PrintedDefinition.extension)
                + (indexer.conformanceExtensionDefinitions[rootTypeName.extensionName] ?? []).map(PrintedDefinition.extension)
                + objcCategoryConformances(filedUnder: rootTypeName.extensionName)
        case .childType(let childTypeName):
            guard let typeDefinition = indexer.allTypeDefinitions[childTypeName] else { throw Error.invalidRuntimeObject }
            return [.type(typeDefinition)]
                + (indexer.typeExtensionDefinitions[childTypeName.extensionName] ?? []).map(PrintedDefinition.extension)
                + (indexer.conformanceExtensionDefinitions[childTypeName.extensionName] ?? []).map(PrintedDefinition.extension)
                + objcCategoryConformances(filedUnder: childTypeName.extensionName)
        case .rootProtocol(let rootProtocolName):
            guard let definition = indexer.rootProtocolDefinitions[rootProtocolName] else { throw Error.invalidRuntimeObject }
            return [.protocol(definition)]
                + defaultImplementationExtensionsLeftToPrint(of: definition)
                + unattachedProtocolExtensions(of: rootProtocolName)
        case .childProtocol(let childProtocolName):
            guard let definition = indexer.allProtocolDefinitions[childProtocolName] else { throw Error.invalidRuntimeObject }
            return [.protocol(definition)]
                + defaultImplementationExtensionsLeftToPrint(of: definition)
                + unattachedProtocolExtensions(of: childProtocolName)
        case .objcProtocol(let objcProtocolName):
            guard let definition = indexer.objcProtocolDefinitions[objcProtocolName] else { throw Error.invalidRuntimeObject }
            return [.objcProtocol(definition)]
        case .typeExtension(let typeExtensionName):
            guard let definitions = indexer.typeExtensionDefinitions[typeExtensionName] else { throw Error.invalidRuntimeObject }
            return definitions.map(PrintedDefinition.extension)
        case .protocolExtension(let protocolExtensionName):
            guard let definitions = indexer.protocolExtensionDefinitions[protocolExtensionName] else { throw Error.invalidRuntimeObject }
            return definitions.map(PrintedDefinition.extension)
        case .typeAliasExtension(let typeAliasExtensionName):
            guard let definitions = indexer.typeAliasExtensionDefinitions[typeAliasExtensionName] else { throw Error.invalidRuntimeObject }
            return definitions.map(PrintedDefinition.extension)
        case .conformance(let conformanceExtensionName):
            let definitions = (indexer.conformanceExtensionDefinitions[conformanceExtensionName] ?? []).map(PrintedDefinition.extension)
                + objcCategoryConformances(filedUnder: conformanceExtensionName)
            guard !definitions.isEmpty else { throw Error.invalidRuntimeObject }
            return definitions
        }
    }

    /// The Objective-C protocols this image's categories adopt for the class
    /// `extensionName` names; see `objcCategoryConformancesByExtensionName`.
    private func objcCategoryConformances(filedUnder extensionName: SwiftDeclaration.ExtensionName) -> [PrintedDefinition] {
        (objcCategoryConformancesByExtensionName[extensionName] ?? []).map { conformance in
            .objcCategoryConformance(conformance, isNotExported: isNotExported(conformance))
        }
    }

    /// The rule MachOSwiftSection's `SwiftInterfaceBuilder` applies to the
    /// category conformances it prints, which RuntimeViewer prints itself: a
    /// conformance goes with a class of this image that is not exported, and
    /// with protocols that are all `@objc` protocols of this image that are
    /// not exported, as a Swift type's conformance to a non-exported protocol
    /// does. One that also adopts an exported or unjudged protocol stays whole.
    private func isNotExported(_ conformance: ObjCCategoryConformance) -> Bool {
        if indexer.allTypeDefinitions[conformance.extendedTypeName]?.exportStatus.isDefinitelyNotExported == true {
            return true
        }
        return !conformance.protocolNames.isEmpty && conformance.protocolNames.allSatisfy { protocolName in
            indexer.objcProtocolDefinitions[protocolName]?.exportStatus.isDefinitelyNotExported == true
        }
    }

    /// The protocol's default implementations, unless the printer prints them
    /// after the declaration itself — MachOSwiftSection's
    /// `printsDefaultImplementationExtensionsAfterDeclaration` says which,
    /// the one statement of that rule its printer and interface builder read
    /// too. A protocol the printer prints without them — nested in a type,
    /// or declared in an extension of another module's type — is printed
    /// here the way its parent prints it inline, and they follow it.
    private func defaultImplementationExtensionsLeftToPrint(of definition: ProtocolDefinition) -> [PrintedDefinition] {
        guard !definition.printsDefaultImplementationExtensionsAfterDeclaration else { return [] }
        return definition.defaultImplementationExtensions.map(PrintedDefinition.extension)
    }

    /// The extensions of a protocol this image declares, less the ones the
    /// indexer attached to it as its default implementations. Those stay in
    /// the indexer's extension table as well, but are printed with the
    /// protocol — see `defaultImplementationExtensionsLeftToPrint(of:)`.
    /// Printing the table's copies too showed every default implementation
    /// two or three times.
    private func unattachedProtocolExtensions(of protocolName: SwiftDeclaration.ProtocolName) -> [PrintedDefinition] {
        (indexer.protocolExtensionDefinitions[protocolName.extensionName] ?? [])
            .filter { !$0.isAttachedToProtocolDefinition }
            .map(PrintedDefinition.extension)
    }

    /// Prints an object's interface with `printer`: every definition of
    /// `printedDefinitions(for:)`, separated by a blank line. Takes the
    /// printer as a parameter because two printers exist — the display one,
    /// configured from the user's generation options, and the corpus one,
    /// marking optional content and nested definitions — and they must print
    /// the same definitions.
    private func printInterface(for object: RuntimeObject, using printer: SwiftDeclarationPrinter<MachO>) async throws -> SemanticString {
        try await Self.printInterface(of: printedDefinitions(for: object), using: printer)
    }

    /// `printInterface(for:using:)` once the definitions are known. Static,
    /// so it runs off the actor: the printer is `Sendable` and the section's
    /// own state is not needed past the definition list.
    private static func printInterface(of definitions: [PrintedDefinition], using printer: SwiftDeclarationPrinter<MachO>) async throws -> SemanticString {
        try await joinedDefinitionPrints(printDefinitions(definitions, using: printer))
    }

    /// Each definition printed on its own, in order, before `joinedDefinitionPrints(_:)` puts them
    /// together.
    private static func printDefinitions(_ definitions: [PrintedDefinition], using printer: SwiftDeclarationPrinter<MachO>) async throws -> [SemanticString] {
        var definitionPrints: [SemanticString] = []
        definitionPrints.reserveCapacity(definitions.count)
        for definition in definitions {
            definitionPrints.append(try await printDefinition(definition, using: printer))
        }
        return definitionPrints
    }

    /// Definitions printed one after another, a blank line between two. A
    /// definition that printed nothing — one the exported-only filter left
    /// out — takes no blank line, so an object whose every definition is left
    /// out prints as empty. In a marked print each blank line is visible only
    /// when a definition on either side of it is (`Joined`), so the corpus,
    /// projected under some options, reads as the content pane prints under
    /// them, blank lines included.
    private static func joinedDefinitionPrints(_ definitionPrints: [SemanticString]) -> SemanticString {
        definitionPrints.joined(separator: SemanticString.doubleBreakLine)
    }

    private static func printDefinition(_ definition: PrintedDefinition, using printer: SwiftDeclarationPrinter<MachO>) async throws -> SemanticString {
        switch definition {
        case .type(let typeDefinition):
            try await printer.printTypeDefinition(typeDefinition)
        case .protocol(let protocolDefinition):
            try await printer.printProtocolDefinition(protocolDefinition)
        case .extension(let extensionDefinition):
            try await printer.printExtensionDefinition(extensionDefinition)
        case .objcProtocol(let objcProtocolDefinition):
            try await printer.printObjCProtocolDefinition(objcProtocolDefinition)
        case .objcCategoryConformance(let objcCategoryConformance, let isNotExported):
            try await printObjCCategoryConformance(objcCategoryConformance, isNotExported: isNotExported, using: printer)
        }
    }

    /// A category conformance as `SwiftInterfaceBuilder.printRoot()` prints
    /// one, which the printer's own export filter never sees: one that is
    /// not exported (`isNotExported(_:)`) is left out while
    /// `printExportedDeclarationsOnly` is on, or, when marking, visible only
    /// while it is off.
    private static func printObjCCategoryConformance(_ conformance: ObjCCategoryConformance, isNotExported: Bool, using printer: SwiftDeclarationPrinter<MachO>) async throws -> SemanticString {
        let configuration = printer.configuration
        guard isNotExported, configuration.printExportedDeclarationsOnly || configuration.marksOptionalContent else {
            return try await printer.printObjCCategoryConformance(conformance)
        }
        guard configuration.marksOptionalContent else { return "" }
        var markedConformance = try await printer.printObjCCategoryConformance(conformance)
        markedConformance.markAtoms(from: 0, visibleUnder: .disabled(SwiftVisibilityOption.printExportedDeclarationsOnly.rawValue))
        return markedConformance
    }
}

extension RuntimeSwiftSection {
    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        #log(.debug, "Getting Swift class hierarchy for: \(object.displayName, privacy: .public)")
        guard case .swift(.type(.class)) = object.kind,
              let classDefinitionName = interfaceDefinitionNameByObject[object.key]?.typeName,
              let classDefinition = indexer.allTypeDefinitions[classDefinitionName],
              case .class(let classDescriptor) = classDefinition.typeContextDescriptorWrapper
        else {
            #log(.debug, "No class hierarchy found")
            return []
        }
        let hierarchy = try Reading.classHierarchy(of: classDescriptor, mangledTypeName: object.name, in: machO, across: factory.indexer)
        #log(.debug, "Class hierarchy: \(hierarchy.count, privacy: .public) levels")
        return hierarchy
    }
}

extension RuntimeSwiftSection {
    /// The source file of each of `discriminators` that a candidate of this image produces; a
    /// discriminator none does is left out. A discriminator nothing recovers runs through every
    /// candidate — seconds for SwiftUI in a debug build — which is why this holds no actor, and
    /// why every answer is remembered.
    nonisolated func privateDeclarationSourceFiles(forDiscriminators discriminators: [String]) async -> [String: RuntimePrivateDeclarationSourceFile] {
        privateDiscriminatorSourceFileIndex.sourceFiles(forDiscriminators: discriminators).mapValues {
            RuntimePrivateDeclarationSourceFile(fileName: $0.fileName, moduleName: $0.moduleName, isSynthesized: $0.isSynthesized)
        }
    }
}

extension RuntimeSwiftSection {
    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        #log(.debug, "Getting member addresses for: \(object.displayName, privacy: .public)")
        // Ensure the definition is indexed by generating the interface (uses internal cache)
        _ = try? await interface(for: object)

        guard let definitionName = interfaceDefinitionNameByObject[object.key] else {
            #log(.debug, "No definition found for: \(object.displayName, privacy: .public)")
            return []
        }

        var result: [RuntimeMemberAddress] = []

        func shouldInclude(_ name: String) -> Bool {
            guard let filter = memberName else { return true }
            return name.lowercased().contains(filter.lowercased())
        }

        func collect(from definition: some Definition, prefix: String = "") {
            for funcDef in definition.functions where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "func",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO),
                    ),
                )
            }
            for funcDef in definition.staticFunctions where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "static func",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO),
                    ),
                )
            }
            for funcDef in definition.constructors where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "init",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO),
                    ),
                )
            }
            for funcDef in definition.allocators where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "allocator",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO),
                    ),
                )
            }
            for varDef in definition.variables where shouldInclude(varDef.name) {
                for accessor in varDef.accessors where accessor.kind != .none {
                    result.append(
                        RuntimeMemberAddress(
                            name: varDef.name,
                            kind: prefix + accessor.kind.kindString,
                            symbolName: accessor.symbol.symbol.name,
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO),
                        ),
                    )
                }
            }
            for varDef in definition.staticVariables where shouldInclude(varDef.name) {
                for accessor in varDef.accessors where accessor.kind != .none {
                    result.append(
                        RuntimeMemberAddress(
                            name: varDef.name,
                            kind: prefix + "static \(accessor.kind.kindString)",
                            symbolName: accessor.symbol.symbol.name,
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO),
                        ),
                    )
                }
            }
            for subscriptDef in definition.subscripts where shouldInclude("subscript") {
                for accessor in subscriptDef.accessors where accessor.kind != .none {
                    result.append(
                        RuntimeMemberAddress(
                            name: "subscript",
                            kind: prefix + "subscript.\(accessor.kind.kindString)",
                            symbolName: accessor.symbol.symbol.name,
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO),
                        ),
                    )
                }
            }
            for subscriptDef in definition.staticSubscripts where shouldInclude("subscript") {
                for accessor in subscriptDef.accessors where accessor.kind != .none {
                    result.append(
                        RuntimeMemberAddress(
                            name: "subscript",
                            kind: prefix + "static subscript.\(accessor.kind.kindString)",
                            symbolName: accessor.symbol.symbol.name,
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO),
                        ),
                    )
                }
            }
        }

        switch definitionName {
        case .rootType(let typeName),
             .childType(let typeName):
            if let typeDefinition = indexer.allTypeDefinitions[typeName] {
                collect(from: typeDefinition)
            }
        case .specializedType(let unspecializedTypeName, let specializedTypeName):
            if let specializedDefinition = specializedDefinitionByObject[object.key] {
                collect(from: specializedDefinition)
            } else if let parentDefinition = indexer.allTypeDefinitions[unspecializedTypeName],
                      let specializedDefinition = parentDefinition.specializedChildren.first(where: { $0.typeName == specializedTypeName }) {
                collect(from: specializedDefinition)
            }
        case .derivedSpecializedType:
            if let specializedDefinition = specializedDefinitionByObject[object.key] {
                collect(from: specializedDefinition)
            }
        case .rootProtocol(let protocolName),
             .childProtocol(let protocolName):
            if let protocolDefinition = indexer.allProtocolDefinitions[protocolName] {
                collect(from: protocolDefinition)
            }
        case .objcProtocol(let protocolName):
            // Its requirements have no symbols; its default implementations do.
            indexer.objcProtocolDefinitions[protocolName]?.defaultImplementationExtensions.forEach { collect(from: $0) }
        case .typeExtension(let extName):
            indexer.typeExtensionDefinitions[extName]?.forEach { collect(from: $0) }
        case .protocolExtension(let extName):
            indexer.protocolExtensionDefinitions[extName]?.forEach { collect(from: $0) }
        case .typeAliasExtension(let extName):
            indexer.typeAliasExtensionDefinitions[extName]?.forEach { collect(from: $0) }
        case .conformance(let extName):
            indexer.conformanceExtensionDefinitions[extName]?.forEach { collect(from: $0) }
        }

        #log(.debug, "Found \(result.count, privacy: .public) member addresses")
        return result
    }
}

extension RuntimeSwiftSection {
    /// Materialize a Swift `RuntimeObject` for a type whose mangled name
    /// is known. Returns `nil` when the mangled key does not map to any
    /// type definition in this section (e.g. it lives in a different image).
    /// Mirrors the construction `_objects(in:)` performs for the same type,
    /// so callers can render relationship results in the same shape as the
    /// sidebar's other Swift entries.
    func makeRuntimeObject(forMangledTypeName mangledName: String) -> RuntimeObject? {
        guard let typeName = indexer.typeName(forMangledName: mangledName),
              let typeDefinition = indexer.allTypeDefinitions[typeName]
        else { return nil }
        var properties: RuntimeObject.Properties = []
        if typeDefinition.typeContextDescriptorWrapper.contextDescriptor.layout.flags.isGeneric {
            properties.insert(.isGeneric)
        }
        let isSpecialized = typeDefinition.isSpecialized
        if isSpecialized {
            properties.insert(.isSpecialized)
        }
        if objcClassPairs.objcClassNameByMangledTypeName[mangledName] != nil {
            properties.insert(.isObjCClass)
        }
        properties.formUnion(typeName.localTypeProperties)
        properties.formUnion(typeDefinition.exportStatus.runtimeObjectProperties)
        let displayName = isSpecialized
            ? typeName.name(using: .interfaceTypeBuilderOnly.subtracting(.removeBoundGeneric))
            : typeName.runtimeObjectDisplayName
        return RuntimeObject(
            name: mangledName,
            displayName: displayName,
            kind: typeName.runtimeObjectKind,
            imagePath: imagePath,
            children: [],
            properties: properties,
            privateDeclarations: typeName.privateDeclarations,
        )
    }

    /// Materialize a Swift `RuntimeObject` for a protocol whose mangled name
    /// is known. The counterpart of `makeRuntimeObject(forMangledTypeName:)`
    /// for the protocol table, so a jump target that resolves to a protocol
    /// (conformance clauses, generic constraints) surfaces in the same shape
    /// as the sidebar's protocol entries. `displayName` uses the
    /// fully-qualified `name`; only `(imagePath, name, kind)` participate in
    /// the object's key, so this stays interchangeable with the section's own
    /// registration regardless of whether it was a root or nested protocol.
    func makeRuntimeObject(forMangledProtocolName mangledName: String) -> RuntimeObject? {
        guard let protocolName = indexer.protocolName(forMangledName: mangledName) else { return nil }
        var properties: RuntimeObject.Properties = objcProtocolPairs.objcProtocolNameByMangledProtocolName[mangledName] == nil ? [] : [.isObjCProtocol]
        // An `@objc` protocol declared in Swift has no `ProtocolDefinition`:
        // its `ObjCProtocolDefinition` carries the verdict its name gives.
        if let protocolDefinition = indexer.allProtocolDefinitions[protocolName] {
            properties.formUnion(protocolDefinition.exportStatus.runtimeObjectProperties)
        } else if let objcProtocolDefinition = indexer.objcProtocolDefinitions[protocolName] {
            properties.formUnion(objcProtocolDefinition.exportStatus.runtimeObjectProperties)
        }
        return RuntimeObject(
            name: mangledName,
            displayName: protocolName.name,
            kind: protocolName.runtimeObjectKind,
            imagePath: imagePath,
            children: [],
            properties: properties,
            privateDeclarations: protocolName.privateDeclarations,
        )
    }

    /// Build the mangledID → indexed type mapping this section contributes
    /// to the factory's cross-image lookup table. Called once per section
    /// immediately after registration; the factory merges the result with
    /// first-write-wins semantics. Mangling is inherently throwing — we
    /// silently skip nodes that fail to mangle, matching the prior loop's
    /// `try?` behaviour.
    func candidateIDMapping() -> [String: RuntimeSwiftSectionFactory<Reading>.IndexedTypeEntry] {
        var result: [String: RuntimeSwiftSectionFactory<Reading>.IndexedTypeEntry] = [:]
        for (typeName, typeDefinition) in indexer.allTypeDefinitions {
            guard let mangled = try? mangleAsString(typeName.node) else { continue }
            result[mangled] = (typeName, MachOIndexedValue(machO: machO, value: typeDefinition), imagePath)
        }
        return result
    }

    /// Protocol counterpart of `candidateIDMapping()`. Kept in a separate
    /// table so a protocol mangled name never collides with (or masks) a
    /// nominal-type candidate consumed by generic specialization.
    func protocolCandidateIDMapping() -> [String: RuntimeSwiftSectionFactory<Reading>.IndexedProtocolEntry] {
        var result: [String: RuntimeSwiftSectionFactory<Reading>.IndexedProtocolEntry] = [:]
        // `@objc` protocols declared in Swift too, so a jump to one resolves.
        let protocolNames = Array(indexer.allProtocolDefinitions.keys) + Array(indexer.objcProtocolDefinitions.keys)
        for protocolName in protocolNames {
            guard let mangled = try? mangleAsString(protocolName.node) else { continue }
            result[mangled] = (protocolName, machO, imagePath)
        }
        return result
    }
}

extension RuntimeSwiftSection {
    // MARK: - Objective-C Counterparts

    /// The Swift class that an Objective-C class of this image is the other
    /// face of, found by the class's runtime name — a Swift mangling
    /// (`_TtC6AppKit…`) and a name spelled in `@objc(…)` (`NSColorModel`)
    /// alike. `nil` for a class that is no Swift class of this image.
    ///
    /// The Inspector's relationship rows reach bridged subclasses through this
    /// too, so the sidebar's jump and those rows cannot disagree.
    func makeRuntimeObject(forObjCRuntimeClassName className: String) -> RuntimeObject? {
        guard let mangledTypeName = objcClassPairs.mangledTypeNameByObjCClassName[className] else { return nil }
        return makeRuntimeObject(forMangledTypeName: mangledTypeName)
    }

    /// The `@objc @implementation` extension holding the Swift bodies of the
    /// Objective-C class `className`, as `allObjects()` listed it.
    func makeRuntimeObject(forObjCImplementationClassNamed className: String) -> RuntimeObject? {
        objcImplementationExtensionObjectByClassName[className]
    }

    /// The runtime name of the Objective-C class `object` is the Swift face
    /// of: a Swift class registered with the Objective-C runtime, or an
    /// `@objc @implementation` extension. `nil` for anything else.
    func objcClassName(forCounterpartOf object: RuntimeObject) -> String? {
        switch object.kind {
        case .swift(.type(.class)):
            return objcClassPairs.objcClassNameByMangledTypeName[object.name]
        case .swift(.extension):
            return objcImplementationClassNameByExtensionMangledName[object.name]
        default:
            return nil
        }
    }

    /// The `@objc` protocol on the Swift side that an Objective-C protocol of
    /// this image is the other face of, found by the protocol's runtime name,
    /// as `allObjects()` listed it. `nil` for a protocol this image does not
    /// declare in Swift — one written in Objective-C, or the copy an image
    /// holds of another module's.
    func makeRuntimeObject(forObjCRuntimeProtocolName protocolName: String) -> RuntimeObject? {
        guard let mangledProtocolName = objcProtocolPairs.mangledProtocolNameByObjCProtocolName[protocolName] else { return nil }
        return makeRuntimeObject(forMangledProtocolName: mangledProtocolName)
    }

    /// The runtime name of the Objective-C protocol `object`, an `@objc`
    /// protocol on the Swift side, is the other face of. `nil` for anything
    /// else.
    func objcProtocolName(forCounterpartOf object: RuntimeObject) -> String? {
        guard case .swift(.type(.protocol)) = object.kind else { return nil }
        return objcProtocolPairs.objcProtocolNameByMangledProtocolName[object.name]
    }

    /// The runtime names `objcProtocolPairs` holds, for the factory's table of
    /// the images that declare them.
    func objcProtocolRuntimeNames() -> [String] {
        Array(objcProtocolPairs.mangledProtocolNameByObjCProtocolName.keys)
    }

    /// Pairs every `@objc` protocol this image declares in Swift with the
    /// Objective-C protocol record MachOSwiftSection matched its declaration
    /// to, by the runtime name the record carries. A protocol renamed with
    /// `@objc(Name)` to a name other than its Swift name matches no record and
    /// is left out.
    private func makeObjCProtocolPairs() -> ObjCProtocolPairs {
        var objcProtocolPairs = ObjCProtocolPairs()
        for (protocolName, definition) in indexer.objcProtocolDefinitions {
            guard let objcProtocolName = definition.objcRuntimeName,
                  let mangledProtocolName = try? mangleAsString(protocolName.node)
            else { continue }
            objcProtocolPairs.objcProtocolNameByMangledProtocolName[mangledProtocolName] = objcProtocolName
            objcProtocolPairs.mangledProtocolNameByObjCProtocolName[objcProtocolName] = mangledProtocolName
        }
        return objcProtocolPairs
    }

    /// Pairs every Swift class this image registers with the Objective-C
    /// runtime — the `__objc_classlist` entries with the Swift bit set — with
    /// its Swift type, through the class object rather than through names.
    ///
    /// A Swift class's class object is its Swift class metadata, which points
    /// at the class's nominal type descriptor: the record the indexer built the
    /// class's `TypeDefinition`, and so its `RuntimeObject`, from. The runtime
    /// name cannot stand in for that pointer. A class declared
    /// `@objc(NSColorModel)` is registered under exactly that name, which
    /// carries neither its module nor its enclosing types, and until
    /// 2026-09-27 such a class found no Swift face and dropped out of the
    /// Inspector's relationship rows.
    ///
    /// A class object that points at a generic descriptor is left out: a
    /// generic class has no class object of its own, and the type the sidebar
    /// lists must not be marked by one of its specializations.
    private func makeObjCClassPairs() -> ObjCClassPairs {
        var objcClassNameByDescriptorOffset: [Int: String] = [:]
        for objcClass in machO.objc.classes64 ?? [] where objcClass.isSwiftStable {
            guard let classDescriptor = try? ClassMetadataObjCInterop.resolve(at: objcClass.offset, in: machO.context).descriptor(in: machO.context),
                  let className = Reading.objcRuntimeName(of: objcClass, in: machO)
            else { continue }
            objcClassNameByDescriptorOffset[classDescriptor.offset] = className
        }
        var objcClassPairs = ObjCClassPairs()
        for (typeName, typeDefinition) in indexer.allTypeDefinitions {
            guard case .class(let classDescriptor) = typeDefinition.typeContextDescriptorWrapper,
                  !classDescriptor.layout.flags.isGeneric,
                  let className = objcClassNameByDescriptorOffset[classDescriptor.offset],
                  let mangledTypeName = try? mangleAsString(typeName.node)
            else { continue }
            objcClassPairs.objcClassNameByMangledTypeName[mangledTypeName] = className
            objcClassPairs.mangledTypeNameByObjCClassName[className] = mangledTypeName
        }
        return objcClassPairs
    }
}

extension RuntimeSwiftSection {
    // MARK: - Generic Specialization

    /// A specializer for type descriptors in `machO`, reading the conformance
    /// provider the factory's aggregate holds for the images indexed right
    /// now.
    ///
    /// Built per request, never kept: a kept specializer keeps its provider,
    /// whose class hierarchy leaves out every image indexed after it was built
    /// (see `RuntimeSwiftInterfaceIndexer.conformanceProvider`). The hierarchy
    /// is the one thing worth keeping, and the shared provider keeps it; the
    /// specializer itself caches nothing.
    private func makeSpecializer(for machO: MachO) -> GenericSpecializer<MachO> {
        let specializer = GenericSpecializer<MachO>(
            machO: machO,
            conformanceProvider: factory.indexer.conformanceProvider,
            indexer: factory.indexer.upstream
        )
        specializer.maxBindingDepth = Self.maxSpecializationDepth
        return specializer
    }

    func specializationRequest(for object: RuntimeObject) async throws -> RuntimeSpecializationRequest {
        do {
            let typeDefinition = try requireGenericTypeDefinition(for: object)
            let upstreamRequest = try makeSpecializer(for: machO).makeRequest(for: typeDefinition.typeContextDescriptorWrapper)
            return try makeRuntimeSpecializationRequest(from: upstreamRequest)
        } catch let error as GenericSpecializer<MachO>.SpecializerError {
            throw Self.translate(error)
        }
    }

    /// Build an inner specialization request for a candidate the user picked
    /// to bind a generic outer parameter. `candidateID` is the mangled string
    /// `mangleAsString(typeName.node)` carried over the wire; we resolve it
    /// via the factory's pre-built mangledID index (populated when each
    /// section registers via `setupForFactory`), so cross-image candidates
    /// (`Array`, `Dictionary` from stdlib) are resolvable in O(1) from any
    /// image that triggered the outer flow.
    /// `imagePath` only feeds the diagnostic on miss; the actual definition
    /// might live in a different image once the aggregate is consulted.
    func specializationRequest(
        forCandidateID candidateID: String,
        in imagePath: String,
    ) async throws -> RuntimeSpecializationRequest {
        guard let matched = await factory.indexedType(forCandidateID: candidateID) else {
            // No human-readable name available on a cold-cache miss — surface
            // the mangled ID so the diagnostic at least round-trips back to
            // a `git grep`-able token in the binary.
            throw RuntimeEngine.EngineError.unindexedCandidate(displayName: candidateID, imagePath: imagePath)
        }
        // Bind the specializer to the candidate's own image, not this
        // section's: the candidate's descriptor can live in a different image
        // (the aggregate is cross-image), and parsing offsets against the
        // wrong Mach-O reads garbage that the demangler later trips on at the
        // first byte.
        let candidateSpecializer = makeSpecializer(for: matched.entry.machO)
        do {
            let upstreamRequest = try candidateSpecializer.makeRequest(for: matched.entry.value.typeContextDescriptorWrapper)
            return try makeRuntimeSpecializationRequest(from: upstreamRequest)
        } catch let error as GenericSpecializer<MachO>.SpecializerError {
            throw Self.translate(error)
        } catch {
            #log(.error, "Inner specialization request failed for candidate \(matched.typeName.name, privacy: .public) (image: \(matched.imagePath, privacy: .public)) requested via section \(imagePath, privacy: .public): \(error, privacy: .public)")
            throw error
        }
    }

    func specialize(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection,
    ) async throws -> RuntimeObject {
        try Task.checkCancellation()
        let baseTypeDefinition = try requireGenericTypeDefinition(for: object)
        let specializer = makeSpecializer(for: machO)
        let upstreamRequest = try specializer.makeRequest(for: baseTypeDefinition.typeContextDescriptorWrapper)
        let resolved = try resolveUpstreamArguments(selection.arguments, against: upstreamRequest)
        try Task.checkCancellation()
        let upstreamSelection = SpecializationSelection(arguments: resolved.arguments)
        // Collect concrete argument typeNodes in declaration order so the
        // upstream `specialize(...)` rewrites the new TypeDefinition's typeName
        // from `Type → Structure(Box)` to `Type → BoundGenericStructure(Type → Structure(Box), TypeList(Type → Structure(Int), …))`.
        // Order must follow `upstreamRequest.parameters`, not the dictionary's
        // arbitrary key order — `BoundGenericStructure`'s TypeList is positional.
        let typeArgumentNodes: [Node] = upstreamRequest.parameters.compactMap { parameter in
            resolved.nodesByParameter[parameter.name]
        }
        let specializedDefinition: TypeDefinition
        do {
            specializedDefinition = try await Reading.specialize(
                baseTypeDefinition,
                request: upstreamRequest,
                selection: upstreamSelection,
                typeArgumentNodes: typeArgumentNodes.count == upstreamRequest.parameters.count ? typeArgumentNodes : nil,
                typeArgumentNodesByParameter: resolved.nodesByParameter,
                using: specializer,
                in: machO,
            )
        } catch let error as GenericSpecializer<MachO>.SpecializerError {
            throw Self.translate(error)
        }
        // After the lone suspension point — bail out before mutating section
        // caches if the caller (UI sheet, MCP request) was cancelled while the
        // upstream specialize was running. The specialized TypeDefinition is
        // still appended to baseTypeDefinition.specializedChildren by upstream;
        // skipping the registration below leaves the section's view of the
        // world consistent (no orphan entry in interfaceDefinitionNameByObject).
        try Task.checkCancellation()
        // Pass the parent generic's typeName so the new runtimeObject is
        // registered as `.specializedType(unspecialized:specialized:)`. Without
        // it `makeRuntimeObject` would fall through to `.childType(boundName)`
        // and `interface(for:)` would later try to look up the bound name in
        // `indexer.allTypeDefinitions` (where only the unbound parent exists),
        // returning `invalidRuntimeObject` and producing an empty Content view
        // until the next reload rebuilt the registration correctly.
        let runtimeObject = try makeRuntimeObject(
            for: specializedDefinition,
            isChild: true,
            unspecializedTypeName: baseTypeDefinition.typeName,
        )
        // Force the parent generic's interface to be re-rendered next time it
        // is requested so that any consumers iterating its
        // `specializedChildren` pick up the newly registered child.
        interfaceByObject.removeValue(forKey: object.key)
        return runtimeObject
    }

    func runtimePreflight(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection,
    ) async throws -> RuntimeSpecializationValidation {
        try Task.checkCancellation()
        let typeDefinition = try requireGenericTypeDefinition(for: object)
        let specializer = makeSpecializer(for: machO)
        let upstreamRequest = try specializer.makeRequest(for: typeDefinition.typeContextDescriptorWrapper)
        let resolved = try resolveUpstreamArguments(selection.arguments, against: upstreamRequest)
        try Task.checkCancellation()
        let upstreamSelection = SpecializationSelection(arguments: resolved.arguments)
        let upstreamValidation = Reading.preflight(upstreamSelection, for: upstreamRequest, using: specializer)
        return Self.translate(upstreamValidation)
    }

    private static func translate(_ validation: SpecializationValidation) -> RuntimeSpecializationValidation {
        RuntimeSpecializationValidation(
            isValid: validation.isValid,
            errors: validation.errors.map(translate(_:)),
            warnings: validation.warnings.map(translate(_:)),
        )
    }

    private static func translate(_ error: SpecializationValidation.Error) -> RuntimeSpecializationValidation.Error {
        switch error {
        case .missingArgument(let parameterName):
            return .missingArgument(parameterName: parameterName)
        case .protocolRequirementNotSatisfied(let parameterName, let protocolName, let actualType):
            return .protocolRequirementNotSatisfied(
                parameterName: parameterName,
                protocolName: protocolName,
                actualType: actualType,
            )
        case .layoutRequirementNotSatisfied(let parameterName, let expectedLayout, let actualType):
            return .layoutRequirementNotSatisfied(
                parameterName: parameterName,
                expectedLayout: String(describing: expectedLayout),
                actualType: actualType,
            )
        case .baseClassRequirementNotSatisfied(let parameterName, let expectedBaseClass, let actualType):
            return .baseClassRequirementNotSatisfied(
                parameterName: parameterName,
                expectedBaseClass: expectedBaseClass,
                actualType: actualType,
            )
        case .sameTypeRequirementNotSatisfied(let parameterName, let expectedType, let actualType):
            return .sameTypeRequirementNotSatisfied(
                parameterName: parameterName,
                expectedType: expectedType,
                actualType: actualType,
            )
        case .metadataResolutionFailed(let parameterName, let reason):
            return .metadataResolutionFailed(parameterName: parameterName, reason: reason)
        case .protocolDescriptorResolutionFailed(let parameterName, let protocolName, let reason):
            return .protocolDescriptorResolutionFailed(
                parameterName: parameterName,
                protocolName: protocolName,
                reason: reason,
            )
        }
    }

    private static func translate(_ warning: SpecializationValidation.Warning) -> RuntimeSpecializationValidation.Warning {
        switch warning {
        case .extraArgument(let parameterName):
            return .extraArgument(parameterName: parameterName)
        case .associatedTypePathInSelection(let path):
            return .associatedTypePathInSelection(path: path)
        case .protocolNotInIndexer(let parameterName, let protocolName):
            return .protocolNotInIndexer(parameterName: parameterName, protocolName: protocolName)
        case .conformanceCheckFailed(let parameterName, let protocolName, let reason):
            return .conformanceCheckFailed(parameterName: parameterName, protocolName: protocolName, reason: reason)
        case .baseClassRequirementResolutionFailed(let parameterName, let reason):
            return .baseClassRequirementResolutionFailed(parameterName: parameterName, reason: reason)
        case .sameTypeRequirementResolutionSkipped(let parameterName, let reason):
            return .sameTypeRequirementResolutionSkipped(parameterName: parameterName, reason: reason)
        }
    }

    private func requireGenericTypeDefinition(for object: RuntimeObject) throws -> TypeDefinition {
        guard let definitionName = interfaceDefinitionNameByObject[object.key],
              let typeName = definitionName.typeName
        else {
            throw Error.invalidRuntimeObject
        }
        if let root = indexer.rootTypeDefinitions[typeName] {
            return root
        }
        if let any = indexer.allTypeDefinitions[typeName] {
            return any
        }
        throw Error.invalidRuntimeObject
    }

    /// Project the upstream `SpecializationRequest` into the public Codable
    /// `RuntimeSpecializationRequest` that crosses the wire.
    private func makeRuntimeSpecializationRequest(
        from upstream: SpecializationRequest,
    ) throws -> RuntimeSpecializationRequest {
        let parameters = try upstream.parameters.map { upstreamParameter -> RuntimeSpecializationRequest.Parameter in
            let candidates = try upstreamParameter.candidates.map { upstreamCandidate -> RuntimeSpecializationRequest.Candidate in
                let id = try mangleAsString(upstreamCandidate.typeName.node)
                let imagePath: String = switch upstreamCandidate.source {
                case .image(let path):
                    path
                }
                let kind: RuntimeSpecializationRequest.Candidate.Kind = switch upstreamCandidate.typeName.kind {
                case .enum: .enum
                case .struct: .struct
                case .class: .class
                }
                return RuntimeSpecializationRequest.Candidate(
                    id: id,
                    displayName: upstreamCandidate.typeName.name,
                    imagePath: imagePath,
                    isGeneric: upstreamCandidate.isGeneric,
                    kind: kind,
                )
            }
            return RuntimeSpecializationRequest.Parameter(
                name: upstreamParameter.name,
                displayDescription: makeParameterDescription(upstreamParameter),
                candidates: candidates,
            )
        }
        return RuntimeSpecializationRequest(parameters: parameters)
    }

    /// Result of resolving a recursive `RuntimeSpecializationSelection`
    /// against an upstream `SpecializationRequest`. Carries both the upstream
    /// arguments (consumed by `specializer.specialize` /
    /// `specializer.runtimePreflight`) and the per-parameter type-argument
    /// nodes (consumed by `TypeDefinition.specialize`'s `boundGenericTypeName`
    /// rewrite). Bundling them keeps the inner `specializer.makeRequest` /
    /// candidate-matching work to a single recursion.
    private struct ResolvedUpstreamArguments {
        var arguments: [String: SpecializationSelection.Argument]
        var nodesByParameter: [String: Node]
    }

    /// Round-trip a Codable `RuntimeSpecializationSelection.arguments` back
    /// into the upstream `SpecializationSelection.Argument` shape by re-running
    /// `makeRequest` and matching each candidate by `(id, imagePath)`.
    ///
    /// Necessary because the on-the-wire selection only carries the opaque
    /// candidate identity (`mangleAsString`-derived); the actual
    /// `SpecializationRequest.Candidate` value (with `TypeName`, `Source`,
    /// etc.) is recreated on the engine that owns the indexer.
    ///
    /// `.boundGeneric` arguments recurse: the matched candidate's
    /// `TypeDefinition` is looked up via `factory.indexer.allTypeDefinitions`
    /// (the shared sub-indexer aggregate, which spans every loaded image so
    /// candidates declared in other images — `Array` / `Dictionary` from the
    /// stdlib — are still resolvable). The inner request is built from that
    /// definition's `typeContextDescriptorWrapper` and the inner arguments are
    /// resolved against it.
    /// Matches MachOSwiftSection's `maxBindingDepth`. Caps our recursive
    /// `.boundGeneric` walk so a deeply nested wire payload can not blow the
    /// stack on the engine side. Breaches surface as the same
    /// `boundGenericInnerFailed` diagnostic the upstream uses, with the
    /// outer-most parameter name attached so the UI can localize.
    private static var maxSpecializationDepth: Int { 16 }

    private func resolveUpstreamArguments(
        _ runtimeArguments: [String: RuntimeSpecializationSelection.Argument],
        against request: SpecializationRequest,
        depth: Int = 0,
    ) throws -> ResolvedUpstreamArguments {
        var result = ResolvedUpstreamArguments(arguments: [:], nodesByParameter: [:])
        for (parameterName, runtimeArgument) in runtimeArguments {
            guard let parameter = request.parameters.first(where: { $0.name == parameterName }) else {
                throw RuntimeEngine.EngineError.specializationParameterNotFound(name: parameterName)
            }
            let resolution = try resolveUpstreamArgument(runtimeArgument, for: parameter, depth: depth)
            result.arguments[parameterName] = resolution.argument
            result.nodesByParameter[parameterName] = resolution.node
        }
        return result
    }

    private func resolveUpstreamArgument(
        _ runtimeArgument: RuntimeSpecializationSelection.Argument,
        for parameter: SpecializationRequest.Parameter,
        depth: Int,
    ) throws -> (argument: SpecializationSelection.Argument, node: Node) {
        switch runtimeArgument {
        case .candidate(let runtimeCandidate):
            let matched = try matchUpstreamCandidate(runtimeCandidate, in: parameter)
            return (.candidate(matched), matched.typeName.node.materialize())
        case .boundGeneric(let runtimeBase, let innerRuntimeArguments):
            guard depth < Self.maxSpecializationDepth else {
                throw RuntimeEngine.EngineError.boundGenericInnerFailed(
                    parameterName: parameter.name,
                    underlying: "Nested specialization depth exceeds the limit of \(Self.maxSpecializationDepth).",
                )
            }
            let matchedBase = try matchUpstreamCandidate(runtimeBase, in: parameter)
            // CRITICAL: inner candidates can live in a different image than
            // the outer generic (`Array` / `Dictionary` live in stdlib, not
            // the outer's hosting image). The outer's specializer is bound to
            // the outer's `machO`, so calling its `makeRequest` on an inner
            // descriptor would parse offsets against the *wrong* Mach-O and
            // read garbage — in practice surfaces as a multi-GB
            // `numberOfElements` inside `TargetGenericContext.initialize` and
            // hangs the process.
            //
            // Build a specializer bound to the inner candidate's own image
            // (mirrors what upstream's internal `makeInnerContext(for:)` does,
            // but expressed here because that helper is `internal`).
            guard let innerEntry = factory.indexer.allAllTypeDefinitions[matchedBase.typeName] else {
                throw RuntimeEngine.EngineError.unindexedCandidate(
                    displayName: runtimeBase.displayName,
                    imagePath: runtimeBase.imagePath,
                )
            }
            let innerSpecializer = makeSpecializer(for: innerEntry.machO)
            let innerRequest: SpecializationRequest
            do {
                innerRequest = try innerSpecializer.makeRequest(for: innerEntry.value.typeContextDescriptorWrapper)
            } catch let error as GenericSpecializer<MachO>.SpecializerError {
                throw Self.translate(error)
            }
            let innerResolved = try resolveUpstreamArguments(
                innerRuntimeArguments,
                against: innerRequest,
                depth: depth + 1,
            )
            let innerNodes: [Node] = innerRequest.parameters.compactMap { innerResolved.nodesByParameter[$0.name] }
            let boundNode = Self.buildBoundGenericNode(base: matchedBase, innerNodes: innerNodes)
            return (
                .boundGeneric(baseCandidate: matchedBase, innerArguments: innerResolved.arguments),
                boundNode,
            )
        }
    }

    private func matchUpstreamCandidate(
        _ runtimeCandidate: RuntimeSpecializationRequest.Candidate,
        in parameter: SpecializationRequest.Parameter,
    ) throws -> SpecializationRequest.Candidate {
        for upstreamCandidate in parameter.candidates {
            guard case .image(let path) = upstreamCandidate.source,
                  path == runtimeCandidate.imagePath else { continue }
            let upstreamID = try mangleAsString(upstreamCandidate.typeName.node)
            if upstreamID == runtimeCandidate.id {
                return upstreamCandidate
            }
        }
        throw RuntimeEngine.EngineError.specializationCandidateNotFound(
            parameterName: parameter.name,
            candidateDisplayName: runtimeCandidate.displayName,
        )
    }

    /// Build a `Type → BoundGenericStructure / Class / Enum(...)` node so the
    /// outer `boundGenericTypeName` rewrite can substitute this as a nested
    /// type argument. Mirrors the shape upstream
    /// `TypeDefinition.boundGenericTypeName(...)` produces; the outer call
    /// will pass our node through `normalizedArgumentNodes`, which is a no-op
    /// when the input is already `.type`-wrapped.
    private static func buildBoundGenericNode(
        base: SpecializationRequest.Candidate,
        innerNodes: [Node],
    ) -> Node {
        let boundKind: Node.Kind = switch base.typeName.kind {
        case .struct: .boundGenericStructure
        case .class: .boundGenericClass
        case .enum: .boundGenericEnum
        }
        let baseNode = wrappedAsType(base.typeName.node.materialize())
        let normalizedInners = innerNodes.map(wrappedAsType)
        let typeList = Node.create(kind: .typeList, children: normalizedInners)
        let boundNode = Node.create(kind: boundKind, children: [baseNode, typeList])
        return Node.create(kind: .type, children: [boundNode])
    }

    private static func wrappedAsType(_ node: Node) -> Node {
        node.kind == .type ? node : Node.create(kind: .type, children: [node])
    }

    /// Translate an upstream `SpecializerError` to a wire-safe
    /// `RuntimeEngine.EngineError` so remote clients (which no longer link
    /// `@_spi(Support) SwiftInterface`) can pattern-match on engine cases.
    private static func translate(_ error: GenericSpecializer<MachO>.SpecializerError) -> Swift.Error {
        switch error {
        case .notGenericType:
            return RuntimeEngine.EngineError.typeNotGeneric
        case .unsupportedGenericParameter:
            return RuntimeEngine.EngineError.unsupportedGenericParameter(description: error.localizedDescription)
        case .boundGenericInnerFailed(let parameterName, let underlying):
            return RuntimeEngine.EngineError.boundGenericInnerFailed(
                parameterName: parameterName,
                underlying: (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)",
            )
        default:
            return error
        }
    }

    /// Pre-format a parameter's constraint list into the display string the UI
    /// renders verbatim (e.g. `A : Hashable & Equatable where A == Foo`).
    /// Engine-side so the view layer never needs to walk
    /// `SpecializationRequest.Requirement`.
    ///
    /// Conformance-style constraints (`.protocol`, `.layout`, `.baseClass`)
    /// are joined after `:` with `&`. `SpecializationRequest` lowers a
    /// declared `<A: P1 & P2>` into individual `.protocol` requirements, so
    /// each token here always corresponds to a single conforming type.
    /// `.sameType` cannot be expressed in the `:`-prefix form, so it is
    /// rendered as a trailing `where A == T` clause.
    private func makeParameterDescription(_ parameter: SpecializationRequest.Parameter) -> String {
        var conformanceTokens: [String] = []
        var sameTypeTargets: [String] = []
        for requirement in parameter.requirements {
            switch requirement {
            case .protocol(let protocolRequirement):
                conformanceTokens.append(protocolRequirement.protocolName.name)
            case .layout(let kind):
                switch kind {
                case .class:
                    conformanceTokens.append("AnyObject")
                }
            case .baseClass(let demangledTypeNode, _):
                conformanceTokens.append(demangledTypeNode.print(using: .interfaceTypeBuilderOnly))
            case .sameType(let demangledTypeNode, _):
                sameTypeTargets.append(demangledTypeNode.print(using: .interfaceTypeBuilderOnly))
            }
        }
        var description = parameter.name
        if !conformanceTokens.isEmpty {
            description += " : \(conformanceTokens.joined(separator: " & "))"
        }
        if !sameTypeTargets.isEmpty {
            let whereClauses = sameTypeTargets.map { "\(parameter.name) == \($0)" }
            description += " where \(whereClauses.joined(separator: ", "))"
        }
        return description
    }
}

extension RuntimeSwiftSection {
    /// Configures the display printer for the next `interface(for:)`. With
    /// `marksCommentStructure` on, it also marks what each comment is, which
    /// `interface(for:)` then separates into the interface's comment
    /// structure; with `marksAttachedMacros` on, it marks each attached
    /// macro's attribute and the definitions printed inside others, from which
    /// `interface(for:)` works out the interface's macro expansions. The text
    /// is the same either way. A change of any of them clears the interface
    /// cache, so an interface with a structure and one without never stand in
    /// for each other.
    func updateConfiguration(using options: SwiftGenerationOptions, transformer: Transformer.SwiftConfiguration, marksCommentStructure: Bool, marksAttachedMacros: Bool) async throws {
        #log(.debug, "Updating Swift section configuration")

        let oldPrintConfiguration = printer.configuration

        let transformerChanged = transformer != lastTransformerConfiguration
        lastTransformerConfiguration = transformer

        var newPrintConfiguration = buildPrintConfiguration(
            from: options,
            oldConfiguration: oldPrintConfiguration,
            transformer: transformer,
            transformerChanged: transformerChanged,
        )
        newPrintConfiguration.marksCommentStructure = marksCommentStructure
        // An attribute region belongs to the innermost definition region
        // around it, or to the definition printed when there is none
        // (`macroExpansions(of:definitionRegions:annotations:)`).
        newPrintConfiguration.marksAttachedMacros = marksAttachedMacros
        newPrintConfiguration.marksNestedDefinitions = marksAttachedMacros

        // The engine updates the section before every interface, nearly
        // always with what it already has. Handing the printer even an equal
        // configuration made an offline printer throw away its static layout
        // calculator, which resolves every image this one depends on — the
        // whole cost of an offline interface, paid on every one.
        if newPrintConfiguration != oldPrintConfiguration {
            printer.updateConfiguration(newPrintConfiguration)
            printerConfigurationUpdateCount += 1
            #log(.debug, "Print configuration changed, clearing interface cache")
            interfaceByObject.removeAll()
            importedInterfaceByObject.removeAll()
        }

        // The printer keeps every resolver it is given and asks each in turn,
        // so the opaque type resolver is registered when the option turns on
        // and dropped when it turns off — never once per update, which
        // stacked a copy for every interface printed.
        if options.resolvesOpaqueTypes, !isOpaqueTypeResolverRegistered {
            printer.addTypeNameResolver(SwiftInterfaceBuilderOpaqueTypeProvider(machO: machO))
            isOpaqueTypeResolverRegistered = true
            opaqueTypeResolverRegistrationCount += 1
        } else if !options.resolvesOpaqueTypes, isOpaqueTypeResolverRegistered {
            printer.removeAllTypeNameResolvers()
            isOpaqueTypeResolverRegistered = false
        }
    }

    // MARK: - Print Configuration Building

    private func buildPrintConfiguration(
        from options: SwiftGenerationOptions,
        oldConfiguration: SwiftDeclarationPrintConfiguration,
        transformer: Transformer.SwiftConfiguration,
        transformerChanged: Bool,
    ) -> SwiftDeclarationPrintConfiguration {
        let swiftInterfaceMemberSortOrder: SwiftDeclarationMemberSortOrder = switch options.memberSortOrder {
        case .byCategory: .byCategory
        case .byOffset: .byOffset
        }

        var newConfiguration = SwiftDeclarationPrintConfiguration(
            memberSortOrder: swiftInterfaceMemberSortOrder,
            memberAddressTransformer: oldConfiguration.memberAddressTransformer,
            vtableOffsetTransformer: oldConfiguration.vtableOffsetTransformer,
            fieldOffsetTransformer: oldConfiguration.fieldOffsetTransformer,
            typeLayoutTransformer: oldConfiguration.typeLayoutTransformer,
            enumLayoutTransformer: oldConfiguration.enumLayoutTransformer,
            enumLayoutCaseTransformer: oldConfiguration.enumLayoutCaseTransformer,
        )
        newConfiguration.applySwitches(of: options)
        newConfiguration.staticLayoutDependencyResolution = factory.staticLayoutDependencyResolution(forImageAt: imagePath)

        // The transformer templates render library-side
        // (`OutputTransformer` + the closure factories in
        // `SwiftDeclarationRendering`); this side only hands the settings
        // over. Reinstalled only on change, because the installed closures
        // are identity-compared by the configuration's `Equatable` (a fresh
        // install would invalidate the interface cache on every update).
        if transformerChanged {
            newConfiguration.applyTransformers(transformer)
        }
        return newConfiguration
    }
}

extension RuntimeSwiftSection {
    private final class ProgressEventHandler: SwiftIndexEvents.Handler, Sendable {
        let continuation: LoadingEventContinuation

        @Mutex
        private var phaseStates: [RuntimeObjectsLoadingProgress.Phase: (currentCount: Int, totalCount: Int)] = [:]

        init(continuation: LoadingEventContinuation) {
            self.continuation = continuation
        }

        func handle(event: SwiftIndexEvents.Payload) {
            switch event {
            case .extractionStarted(let section):
                if let phase = extractionPhase(for: section) {
                    yieldProgress(phase: phase, itemDescription: "", currentCount: 0, totalCount: 0)
                }
            case .typeIndexingStarted(let totalTypes):
                phaseStates[.indexingSwiftTypes] = (0, totalTypes)
            case .typeProcessed(let context):
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: context.typeName)
            case .typeProcessingFailed:
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: "")
            case .typeProcessingSkippedCImported:
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: "")
            case .protocolIndexingStarted(let totalProtocols):
                phaseStates[.indexingSwiftProtocols] = (0, totalProtocols)
            case .protocolProcessed(let context):
                incrementAndYield(phase: .indexingSwiftProtocols, itemDescription: context.protocolName)
            case .protocolProcessingFailed:
                incrementAndYield(phase: .indexingSwiftProtocols, itemDescription: "")
            case .conformanceIndexingStarted(let input):
                phaseStates[.indexingSwiftConformances] = (0, input.totalConformances)
            case .conformanceFound(let context):
                incrementAndYield(phase: .indexingSwiftConformances, itemDescription: "\(context.typeName): \(context.protocolName)")
            case .conformanceProcessingFailed:
                incrementAndYield(phase: .indexingSwiftConformances, itemDescription: "")
            case .extensionIndexingStarted:
                phaseStates[.indexingSwiftExtensions] = (0, 0)
            case .extensionCreated(let context):
                incrementAndYield(phase: .indexingSwiftExtensions, itemDescription: context.targetName)
            case .extensionCreationFailed:
                incrementAndYield(phase: .indexingSwiftExtensions, itemDescription: "")
            case .symbolIndexProgress(let currentCount, let totalCount):
                yieldProgress(phase: .preparingSymbolIndex, itemDescription: "", currentCount: currentCount, totalCount: totalCount)
            default:
                break
            }
        }

        private func extractionPhase(for section: SwiftIndexEvents.Section) -> RuntimeObjectsLoadingProgress.Phase? {
            switch section {
            case .swiftTypes: return .extractingSwiftTypes
            case .swiftProtocols: return .extractingSwiftProtocols
            case .protocolConformances: return .extractingSwiftConformances
            case .associatedTypes: return .extractingSwiftAssociatedTypes
            case .symbolIndex: return .preparingSymbolIndex
            }
        }

        private func incrementAndYield(phase: RuntimeObjectsLoadingProgress.Phase, itemDescription: String) {
            let state = _phaseStates.withLock { dictionary in
                var current = dictionary[phase] ?? (0, 0)
                current.currentCount += 1
                dictionary[phase] = current
                return current
            }
            yieldProgress(phase: phase, itemDescription: itemDescription, currentCount: state.currentCount, totalCount: state.totalCount)
        }

        private func yieldProgress(phase: RuntimeObjectsLoadingProgress.Phase, itemDescription: String, currentCount: Int, totalCount: Int) {
            continuation.yield(RuntimeObjectsLoadingEvent.progress(RuntimeObjectsLoadingProgress(
                phase: phase,
                itemDescription: itemDescription,
                currentCount: currentCount,
                totalCount: totalCount,
            )))
        }
    }
}

extension SwiftDeclaration.ProtocolName {
    fileprivate var runtimeObjectKind: RuntimeObjectKind {
        return .swift(.type(.protocol))
    }
}

extension SwiftDeclaration.ExtensionName {
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

extension SwiftDeclaration.DefinitionName {
    /// The private declarations this name reads, as MachOSwiftSection reads them
    /// (`DemanglingNode.privateDeclarations`): in the order the name reads them, each once, a
    /// declaring function's signature and a position-based local type's `$` address left out.
    /// Display names are printed without discriminators, so `RuntimeObject.privateDeclarations`
    /// is where they are kept.
    fileprivate var privateDeclarations: [RuntimePrivateDeclaration] {
        node.privateDeclarations.map { RuntimePrivateDeclaration(name: $0.name, discriminator: $0.discriminator) }
    }

    /// The name an object is listed under: a type declared in a function or closure body, or one
    /// nested in such a type, the way MachOSwiftSection says it to a reader
    /// (`Visitor #1 in TableDataSource.performDrop(to:)`) — the compiler's own name carries the
    /// function's whole signature; every other name as `name` prints it.
    fileprivate var runtimeObjectDisplayName: String {
        localTypeDisplayName ?? name
    }
}

extension ExportStatus {
    /// `isNotExported` on MachOSwiftSection's one verdict filtering may act
    /// on — the descriptor symbol is provably not in the export trie — and
    /// nothing on every other status, which is no verdict.
    fileprivate var runtimeObjectProperties: RuntimeObject.Properties {
        isDefinitelyNotExported ? .isNotExported : []
    }
}

extension SwiftDeclaration.TypeName {
    /// `isLocalType` for a type declared in a function or closure body, with
    /// `isPositionNamedLocalType` when the binary names no function for it.
    fileprivate var localTypeProperties: RuntimeObject.Properties {
        switch node.localTypeNaming {
        case .compilerSpelled?:
            [.isLocalType]
        case .positionBased?:
            [.isLocalType, .isPositionNamedLocalType]
        case nil:
            []
        }
    }
}

extension ExtensionName {
    fileprivate var typeName: SwiftDeclaration.TypeName? {
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

    fileprivate var protocolName: SwiftDeclaration.ProtocolName? {
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

extension SwiftDeclaration.AccessorKind {
    fileprivate var kindString: String {
        switch self {
        case .getter: return "getter"
        case .setter: return "setter"
        case .modifyAccessor: return "modifyAccessor"
        case .readAccessor: return "readAccessor"
        case .borrowAccessor: return "borrowAccessor"
        case .mutateAccessor: return "mutateAccessor"
        case .initAccessor: return "initAccessor"
        case .none: return "none"
        }
    }
}

// MARK: - Corpus

extension RuntimeSwiftSection {
    /// The corpus prints of `family` — an object, then the objects nested in
    /// it, each after the object it is nested in — one outcome per object.
    ///
    /// The first object is printed with the corpus printer, marked for every
    /// combination of the Generation Options and around every nested
    /// definition. Each object nested in it then takes its own definition out
    /// of that print instead of printing it again (`0029-find-navigator`
    /// §1.1, option D: nested types are about four tenths of what an image
    /// prints), and prints only what follows its definition — its extensions,
    /// a protocol's default implementations. One whose definition cannot be
    /// taken out is printed on its own: it failed to print inside its parent,
    /// or a hand-written transformer did not indent by the level it was given.
    /// So is one the exported-only filter keeps inside an object it leaves out
    /// (`objectsKeptInsideUnexportedObjects(below:)`). Either way an interface
    /// comes out exactly as the content pane prints it.
    ///
    /// The members are read off the definitions those prints indexed: Swift
    /// definitions index their members lazily, and the only public trigger is
    /// printing, which a nested definition gets inside its parent's print.
    ///
    /// Only the definition lists and the printer come from the section; the
    /// printing, the freezing, the separations and the member listing run off
    /// the actor, so the content pane is never kept waiting behind a corpus
    /// build and families of one image print side by side.
    nonisolated func corpusPrints(of family: [RuntimeObject], transformer: Transformer.Configuration) async throws -> [RuntimeInterfaceCorpusPrintOutcome] {
        guard let root = family.first else { return [] }
        let inputs = await corpusPrintingInputs(for: family, transformer: transformer.swift)
        let objectsPrintedOnTheirOwn = Self.objectsKeptInsideUnexportedObjects(below: root)
        var outcomes: [RuntimeInterfaceCorpusPrintOutcome] = []
        outcomes.reserveCapacity(family.count)
        var rootPrint: (marked: FrozenSemanticString, regionsByObject: [RuntimeObjectKey: DefinitionRegionTable.Region])?
        for (index, object) in family.enumerated() {
            try Task.checkCancellation()
            let definitions: [PrintedDefinition]
            switch inputs.definitions[index] {
            case .success(let printedDefinitions):
                definitions = printedDefinitions
            case .failure(let error):
                outcomes.append(.failed("\(error)"))
                continue
            }
            do {
                let marked: FrozenSemanticString
                if index > 0,
                   !objectsPrintedOnTheirOwn.contains(object.key),
                   let rootPrint,
                   let region = rootPrint.regionsByObject[object.key],
                   let ownDefinition = RuntimeInterfaceCorpusNesting.ownDefinition(in: rootPrint.marked, region: region) {
                    var definitionPrints = [SemanticString(components: ownDefinition.components)]
                    for definition in definitions.dropFirst() {
                        definitionPrints.append(try await Self.printDefinition(definition, using: inputs.printer))
                    }
                    marked = Self.joinedDefinitionPrints(definitionPrints).frozen()
                } else {
                    marked = try await Self.printInterface(of: definitions, using: inputs.printer).frozen()
                }
                let separated = RuntimeInterfaceCorpusNesting.separate(marked, childNames: Set(object.children.map(\.name)))
                if index == 0 {
                    rootPrint = (marked, RuntimeInterfaceCorpusNesting.descendantRegions(of: root, in: separated.definitionRegions))
                }
                outcomes.append(.printed(RuntimeInterfaceCorpusPrint(
                    object: object,
                    interface: separated.interface,
                    visibilityRegions: separated.visibilityRegions,
                    members: Self.memberDeclarations(of: definitions),
                    nestedDefinitionRanges: separated.nestedDefinitionRanges
                )))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(.failed("\(error)"))
            }
        }
        return outcomes
    }

    /// The objects nested in `root` that are not marked `isNotExported` but
    /// lie inside an object that is. A type nested in a type its image does
    /// not export can itself be exported — Foundation's
    /// `LocalePreferences.ICUSymbolsAndStrings` is — and in the marked print
    /// of the type around it, it sits in that type's region, visible only
    /// while the exported-only filter is off; printed on its own it has no
    /// such region. Its definition taken out of that print would hide it from
    /// a search the content pane shows it to.
    private static func objectsKeptInsideUnexportedObjects(below root: RuntimeObject) -> Set<RuntimeObjectKey> {
        var keptObjects: Set<RuntimeObjectKey> = []
        func visit(_ object: RuntimeObject, isInsideUnexportedObject: Bool) {
            let isNotExported = object.properties.contains(.isNotExported)
            if isInsideUnexportedObject, !isNotExported {
                keptObjects.insert(object.key)
            }
            for child in object.children {
                visit(child, isInsideUnexportedObject: isInsideUnexportedObject || isNotExported)
            }
        }
        visit(root, isInsideUnexportedObject: false)
        return keptObjects
    }

    /// What a family's corpus prints take from the section's state: each
    /// object's definitions, or why it has none, and the printer.
    private func corpusPrintingInputs(for family: [RuntimeObject], transformer: Transformer.SwiftConfiguration) -> (definitions: [Result<[PrintedDefinition], any Swift.Error>], printer: SwiftDeclarationPrinter<MachO>) {
        (family.map { object in Result { try printedDefinitions(for: object) } }, corpusPrinter(for: transformer))
    }

    /// A printer that marks optional content instead of letting the options
    /// decide it, so one print serves every combination of them, and marks
    /// the nested definitions it prints inline, so an object nested in
    /// another takes its own definition out of its parent's print. The opaque
    /// type resolver is always registered: the constraints it supplies are
    /// marked, and a search with `synthesizeOpaqueType` off projects them
    /// away. The member order is the fixed by-category one — a reordering is
    /// not something a region can express.
    private func corpusPrinter(for transformer: Transformer.SwiftConfiguration) -> SwiftDeclarationPrinter<MachO> {
        if let corpusPrinter, corpusPrinterTransformer == transformer {
            return corpusPrinter
        }
        let printer = SwiftDeclarationPrinter<MachO>(configuration: .init(), eventHandlers: [], in: machO)
        var configuration = buildPrintConfiguration(
            from: RuntimeObjectInterface.GenerationOptions.mcp.swiftInterfaceOptions,
            oldConfiguration: printer.configuration,
            transformer: transformer,
            transformerChanged: true,
        )
        configuration.marksOptionalContent = true
        configuration.marksNestedDefinitions = true
        configuration.memberSortOrder = .byCategory
        printer.updateConfiguration(configuration)
        printer.addTypeNameResolver(SwiftInterfaceBuilderOpaqueTypeProvider(machO: machO))
        Self.installExportFilterScope(on: printer, from: indexer)
        corpusPrinter = printer
        corpusPrinterTransformer = transformer
        return printer
    }

    /// The members `definitions` list, not yet located in any text. Reads
    /// whatever the definitions have indexed so far; after they are printed,
    /// that is everything.
    ///
    /// A protocol's default implementations are its members wherever they
    /// end up printed: the printer trails a top-level protocol with them
    /// itself, and `printedDefinitions(for:)` appends them after any other
    /// protocol. So they are listed with the protocol, from its
    /// `defaultImplementationExtensions`, in the order they print, and an
    /// extension that is one of them is skipped when it comes up as a
    /// definition of its own — whoever prints them, the list does not need to
    /// know. Identity decides, not `isAttachedToProtocolDefinition`:
    /// MachOSwiftSection synthesizes an unflagged default-implementation
    /// extension for a protocol no symbol-scan extension block was attached
    /// to.
    static func memberDeclarations(of definitions: [PrintedDefinition]) -> [RuntimeMemberDeclaration] {
        var members: [RuntimeMemberDeclaration] = []
        var listedDefaultImplementationExtensions: Set<ObjectIdentifier> = []
        for definition in definitions {
            switch definition {
            case .type(let typeDefinition):
                let fieldKind: RuntimeMemberKind = typeDefinition.typeName.kind == .enum ? .swiftEnumCase : .swiftField
                for field in typeDefinition.fields {
                    members.append(RuntimeMemberDeclaration(name: field.name, kind: fieldKind, isStatic: false, declarationText: field.name, lineNumber: nil))
                }
                members += Self.memberDeclarations(of: typeDefinition)
            case .protocol(let protocolDefinition):
                members += Self.memberDeclarations(of: protocolDefinition)
                for extensionDefinition in protocolDefinition.defaultImplementationExtensions {
                    listedDefaultImplementationExtensions.insert(ObjectIdentifier(extensionDefinition))
                    members += Self.memberDeclarations(of: extensionDefinition)
                }
            case .extension(let extensionDefinition):
                guard !listedDefaultImplementationExtensions.contains(ObjectIdentifier(extensionDefinition)) else { continue }
                members += Self.memberDeclarations(of: extensionDefinition)
            case .objcProtocol(let objcProtocolDefinition):
                members += objcProtocolDefinition.requirements.map(Self.memberDeclaration(of:))
                for extensionDefinition in objcProtocolDefinition.defaultImplementationExtensions {
                    listedDefaultImplementationExtensions.insert(ObjectIdentifier(extensionDefinition))
                    members += Self.memberDeclarations(of: extensionDefinition)
                }
            case .objcCategoryConformance:
                // `extension Class: P {}` declares no members.
                continue
            }
        }
        return members
    }

    /// A requirement of an `@objc` protocol under the name the interface
    /// prints it with — its Swift declaration's, not its selector. The
    /// requirements are read when the protocol is printed, which the corpus
    /// does before it lists members.
    private static func memberDeclaration(of requirement: ObjCProtocolRequirementDefinition) -> RuntimeMemberDeclaration {
        switch requirement.kind {
        case .initializer:
            return RuntimeMemberDeclaration(name: "init", kind: .swiftInitializer, isStatic: true, declarationText: "init", lineNumber: nil)
        case .subscript:
            return RuntimeMemberDeclaration(name: "subscript", kind: .swiftSubscript, isStatic: requirement.isClassMember, declarationText: "subscript", lineNumber: nil)
        case .method:
            let name = declaredName(of: requirement)
            return RuntimeMemberDeclaration(name: name, kind: .swiftFunction, isStatic: requirement.isClassMember, declarationText: name, lineNumber: nil)
        case .property:
            let name = declaredName(of: requirement)
            return RuntimeMemberDeclaration(name: name, kind: .swiftVariable, isStatic: requirement.isClassMember, declarationText: name, lineNumber: nil)
        }
    }

    /// The identifier of a method's or property's declaration —
    /// `Global > Function` or `Global > (Static >) Getter > Variable`, whose
    /// first child is the context the identifier follows. The selector stands
    /// in should the node ever carry none.
    private static func declaredName(of requirement: ObjCProtocolRequirementDefinition) -> String {
        let declarationNode = requirement.node.materialize().first(of: .function, .variable)
        return declarationNode?.children.first { $0.kind == .identifier }?.text ?? requirement.selector
    }

    private static func memberDeclarations(of definition: some Definition) -> [RuntimeMemberDeclaration] {
        var members: [RuntimeMemberDeclaration] = []
        // A class prints its allocating initializers; a value type has none
        // and prints its constructors. Listing both would show every class
        // initializer twice.
        let initializers = definition.allocators.isEmpty ? definition.constructors : definition.allocators
        for _ in initializers {
            members.append(RuntimeMemberDeclaration(name: "init", kind: .swiftInitializer, isStatic: true, declarationText: "init", lineNumber: nil))
        }
        for variable in definition.variables {
            members.append(RuntimeMemberDeclaration(name: variable.name, kind: .swiftVariable, isStatic: false, declarationText: variable.name, lineNumber: nil))
        }
        for variable in definition.staticVariables {
            members.append(RuntimeMemberDeclaration(name: variable.name, kind: .swiftVariable, isStatic: true, declarationText: variable.name, lineNumber: nil))
        }
        for function in definition.functions {
            members.append(RuntimeMemberDeclaration(name: function.name, kind: .swiftFunction, isStatic: false, declarationText: function.name, lineNumber: nil))
        }
        for function in definition.staticFunctions {
            members.append(RuntimeMemberDeclaration(name: function.name, kind: .swiftFunction, isStatic: true, declarationText: function.name, lineNumber: nil))
        }
        for _ in definition.subscripts {
            members.append(RuntimeMemberDeclaration(name: "subscript", kind: .swiftSubscript, isStatic: false, declarationText: "subscript", lineNumber: nil))
        }
        for _ in definition.staticSubscripts {
            members.append(RuntimeMemberDeclaration(name: "subscript", kind: .swiftSubscript, isStatic: true, declarationText: "subscript", lineNumber: nil))
        }
        return members
    }
}
