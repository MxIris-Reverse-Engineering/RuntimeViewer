import Demangling
import Foundation
import FoundationToolbox
import FrameworkToolbox
import MachOKit
import MachOSwiftSection
import OrderedCollections
import Semantic
import SwiftDump
@_spi(Internals) import SwiftInspection
@_spi(Support) import SwiftInterface
import MetaCodable

@Codable
@MemberInit
public struct SwiftGenerationOptions: Sendable, Equatable {
    public enum MemberSortOrder: String, Codable, Sendable, Equatable, CaseIterable {
        case byCategory
        case byOffset
    }
    @Default(true)
    public var printStrippedSymbolicItem: Bool
    
    @Default(false)
    public var printFieldOffset: Bool
    
    @Default(false)
    public var printExpandedFieldOffset: Bool
    
    @Default(false)
    public var printVTableOffset: Bool
    
    @Default(false)
    public var printPWTOffset: Bool
    
    @Default(false)
    public var printMemberAddress: Bool
    
    @Default(false)
    public var printTypeLayout: Bool
    
    @Default(false)
    public var printEnumLayout: Bool
    
    @Default(false)
    public var synthesizeOpaqueType: Bool
    
    @Default(MemberSortOrder.byCategory)
    public var memberSortOrder: MemberSortOrder

    public static let `default` = Self()
}

@Loggable(.private)
actor RuntimeSwiftSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObject
    }

    let imagePath: String

    private let machO: MachOImage

    private let factory: RuntimeSwiftSectionFactory

    private var indexer: SwiftInterfaceIndexer<MachOImage>

    private var printer: SwiftInterfacePrinter<MachOImage>

    private var interfaceByObject: OrderedDictionary<RuntimeObject, RuntimeObjectInterface> = [:]

    private var lastTransformerConfiguration: Transformer.SwiftConfiguration = .init()

    private var interfaceDefinitionNameByObject: [RuntimeObject: InterfaceDefinitionName] = [:]

    /// Lazily-constructed specializer reused for both `makeRequest(for:)`
    /// and `specialize(_:with:)`. Lives on the actor so the underlying
    /// indexer reference is captured exactly once and the caches built by
    /// repeated `findCandidates` invocations stay warm across user
    /// interactions.
    private lazy var specializer: GenericSpecializer<MachOImage> = .init(machO: machO, conformanceProvider: IndexerConformanceProvider(indexer: factory.indexer), indexer: factory.indexer)

    private enum InterfaceDefinitionName {
        case rootType(SwiftInterface.TypeName)
        case childType(SwiftInterface.TypeName)
        /// Specialized children: each carries the unspecialized parent's
        /// `TypeName` (the lookup key into `indexer.allTypeDefinitions`)
        /// alongside the bound `TypeName` produced by
        /// `TypeDefinition.boundGenericTypeName(...)` (used to disambiguate
        /// inside the parent's `specializedChildren` array, since
        /// specialized definitions live on the parent rather than on the
        /// indexer).
        case specializedType(unspecialized: SwiftInterface.TypeName, specialized: SwiftInterface.TypeName)
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

    private final class ProgressEventHandler: SwiftInterfaceEvents.Handler, Sendable {
        let continuation: LoadingEventContinuation

        @Mutex
        private var phaseStates: [RuntimeObjectsLoadingProgress.Phase: (currentCount: Int, totalCount: Int)] = [:]

        init(continuation: LoadingEventContinuation) {
            self.continuation = continuation
        }

        func handle(event: SwiftInterfaceEvents.Payload) {
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

        private func extractionPhase(for section: SwiftInterfaceEvents.Section) -> RuntimeObjectsLoadingProgress.Phase? {
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
                totalCount: totalCount
            )))
        }
    }

    init(imagePath: String, factory: RuntimeSwiftSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing Swift section for image: \(imagePath, privacy: .public)")
        guard let machO = DyldUtilities.machOImage(forPath: imagePath) else {
            #log(.error, "Failed to create MachOImage for: \(imagePath, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.factory = factory
        self.imagePath = imagePath
        self.machO = machO
        #log(.debug, "Creating Swift Interface Components")
        let eventHandlers: [SwiftInterfaceEvents.Handler] = progressContinuation.map { [ProgressEventHandler(continuation: $0)] } ?? []
        self.indexer = .init(configuration: .init(showCImportedTypes: false), eventHandlers: eventHandlers, in: machO)
        self.printer = .init(configuration: .init(), eventHandlers: [], in: machO)
        try await indexer.prepare()
        #log(.info, "Swift section initialized successfully")
    }

    func updateConfiguration(using options: SwiftGenerationOptions, transformer: Transformer.SwiftConfiguration) async throws {
        #log(.debug, "Updating Swift section configuration")

        let oldIndexConfiguration = indexer.configuration
        let newIndexConfiguration = SwiftInterfaceIndexConfiguration(showCImportedTypes: false)
        try await indexer.updateConfiguration(newIndexConfiguration)

        let oldPrintConfiguration = printer.configuration

        let transformerChanged = transformer != lastTransformerConfiguration
        lastTransformerConfiguration = transformer

        let newPrintConfiguration = buildPrintConfiguration(
            from: options,
            oldConfiguration: oldPrintConfiguration,
            transformer: transformer,
            transformerChanged: transformerChanged
        )
        printer.updateConfiguration(newPrintConfiguration)

        if options.synthesizeOpaqueType {
            printer.addTypeNameResolver(SwiftInterfaceBuilderOpaqueTypeProvider(machO: machO))
        } else {
            printer.removeAllTypeNameResolvers()
        }

        if newIndexConfiguration.showCImportedTypes != oldIndexConfiguration.showCImportedTypes {
            #log(.debug, "Index configuration changed, re-preparing builder")
            interfaceDefinitionNameByObject.removeAll()
        }

        if newPrintConfiguration != oldPrintConfiguration {
            #log(.debug, "Print configuration changed, clearing interface cache")
            interfaceByObject.removeAll()
        }
    }

    // MARK: - Print Configuration Building

    private func buildPrintConfiguration(
        from options: SwiftGenerationOptions,
        oldConfiguration: SwiftInterfacePrintConfiguration,
        transformer: Transformer.SwiftConfiguration,
        transformerChanged: Bool
    ) -> SwiftInterfacePrintConfiguration {
        var fieldOffsetTransformer: FieldOffsetTransformer? = oldConfiguration.fieldOffsetTransformer
        var vtableOffsetTransformer: VTableOffsetTransformer? = oldConfiguration.vtableOffsetTransformer
        var memberAddressTransformer: MemberAddressTransformer? = oldConfiguration.memberAddressTransformer
        var typeLayoutTransformer: TypeLayoutTransformer? = oldConfiguration.typeLayoutTransformer
        var enumLayoutTransformer: EnumLayoutTransformer? = oldConfiguration.enumLayoutTransformer
        var enumLayoutCaseTransformer: EnumLayoutCaseTransformer? = oldConfiguration.enumLayoutCaseTransformer

        if transformerChanged {
            vtableOffsetTransformer = buildVTableOffsetTransformer(from: transformer)
            memberAddressTransformer = buildMemberAddressTransformer(from: transformer)
            fieldOffsetTransformer = buildFieldOffsetTransformer(from: transformer)
            typeLayoutTransformer = buildTypeLayoutTransformer(from: transformer)
            (enumLayoutTransformer, enumLayoutCaseTransformer) = buildEnumLayoutTransformers(from: transformer)
        }

        let swiftInterfaceMemberSortOrder: SwiftInterfaceMemberSortOrder = switch options.memberSortOrder {
        case .byCategory: .byCategory
        case .byOffset: .byOffset
        }

        return SwiftInterfacePrintConfiguration(
            printStrippedSymbolicItem: options.printStrippedSymbolicItem,
            printFieldOffset: options.printFieldOffset,
            printExpandedFieldOffsets: options.printExpandedFieldOffset,
            printMemberAddress: options.printMemberAddress,
            printVTableOffset: options.printVTableOffset,
            printPWTOffset: options.printPWTOffset,
            memberSortOrder: swiftInterfaceMemberSortOrder,
            printTypeLayout: options.printTypeLayout,
            printEnumLayout: options.printEnumLayout,
            memberAddressTransformer: memberAddressTransformer,
            vtableOffsetTransformer: vtableOffsetTransformer,
            fieldOffsetTransformer: fieldOffsetTransformer,
            typeLayoutTransformer: typeLayoutTransformer,
            enumLayoutTransformer: enumLayoutTransformer,
            enumLayoutCaseTransformer: enumLayoutCaseTransformer
        )
    }

    // MARK: - Transformer Builders

    private func buildVTableOffsetTransformer(from transformer: Transformer.SwiftConfiguration) -> VTableOffsetTransformer? {
        guard transformer.swiftVTableOffset.isEnabled else { return nil }
        let module = transformer.swiftVTableOffset
        return VTableOffsetTransformer { input in
            let result = module.transform(.init(slotOffset: input.slotOffset, label: input.label))
            return Comment(result).asSemanticString()
        }
    }

    private func buildMemberAddressTransformer(from transformer: Transformer.SwiftConfiguration) -> MemberAddressTransformer? {
        guard transformer.swiftMemberAddress.isEnabled else { return nil }
        let module = transformer.swiftMemberAddress
        return MemberAddressTransformer { offset in
            let result = module.transform(.init(offset: offset))
            return Comment(result).asSemanticString()
        }
    }

    private func buildFieldOffsetTransformer(from transformer: Transformer.SwiftConfiguration) -> FieldOffsetTransformer? {
        guard transformer.swiftFieldOffset.isEnabled else { return nil }
        let module = transformer.swiftFieldOffset
        return FieldOffsetTransformer { input in
            let result = module.transform(.init(startOffset: input.startOffset, endOffset: input.endOffset))
            return Comment(result).asSemanticString()
        }
    }

    private func buildTypeLayoutTransformer(from transformer: Transformer.SwiftConfiguration) -> TypeLayoutTransformer? {
        guard transformer.swiftTypeLayout.isEnabled else { return nil }
        let module = transformer.swiftTypeLayout
        return TypeLayoutTransformer { typeLayout in
            let input = Transformer.SwiftTypeLayout.Input(
                size: Int(typeLayout.size),
                stride: Int(typeLayout.stride),
                alignment: Int(typeLayout.flags.alignment),
                extraInhabitantCount: Int(typeLayout.extraInhabitantCount),
                isPOD: typeLayout.flags.isPOD,
                isInlineStorage: typeLayout.flags.isInlineStorage,
                isBitwiseTakable: typeLayout.flags.isBitwiseTakable,
                isBitwiseBorrowable: typeLayout.flags.isBitwiseBorrowable,
                isCopyable: typeLayout.flags.isCopyable,
                hasEnumWitnesses: typeLayout.flags.hasEnumWitnesses,
                isIncomplete: typeLayout.flags.isIncomplete
            )
            let result = module.transform(input)
            return Comment(result).asSemanticString()
        }
    }

    private func buildEnumLayoutTransformers(from transformer: Transformer.SwiftConfiguration) -> (EnumLayoutTransformer?, EnumLayoutCaseTransformer?) {
        guard transformer.swiftEnumLayout.isEnabled else { return (nil, nil) }
        let module = transformer.swiftEnumLayout

        let layoutTransformer = EnumLayoutTransformer { layoutResult in
            let payloadCaseCount = layoutResult.cases.filter { $0.caseName.hasPrefix("Payload") }.count
            let emptyCaseCount = layoutResult.cases.filter { $0.caseName.hasPrefix("Empty") }.count
            let input = Transformer.SwiftEnumLayout.Input(
                strategy: layoutResult.strategyDescription,
                bitsNeededForTag: layoutResult.bitsNeededForTag,
                bitsAvailableForPayload: layoutResult.bitsAvailableForPayload,
                numTags: layoutResult.numTags,
                totalCases: layoutResult.cases.count,
                payloadCaseCount: payloadCaseCount,
                emptyCaseCount: emptyCaseCount,
                tagRegionRange: layoutResult.tagRegion.map { "\($0.range)" } ?? "N/A",
                tagRegionBitCount: layoutResult.tagRegion?.bitCount ?? 0,
                tagRegionBytesHex: layoutResult.tagRegion.map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "N/A",
                payloadRegionRange: layoutResult.payloadRegion.map { "\($0.range)" } ?? "N/A",
                payloadRegionBitCount: layoutResult.payloadRegion?.bitCount ?? 0,
                payloadRegionBytesHex: layoutResult.payloadRegion.map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "N/A"
            )
            let result = module.transform(input)
            return InlineComment(result).asSemanticString()
        }

        let caseTransformer = EnumLayoutCaseTransformer { input in
            let caseProjection = input.caseProjection
            let indentation = input.indentation
            let caseType: String = caseProjection.caseName.hasPrefix("Payload") ? "Payload" : "Empty"
            let memoryChangesDetail = caseProjection.memoryChanges
                .sorted(by: { $0.key < $1.key })
                .map { "[\($0.key)]=0x\(String(format: "%02X", $0.value))" }
                .joined(separator: ", ")
            let caseInput = Transformer.SwiftEnumLayout.CaseInput(
                caseIndex: caseProjection.caseIndex,
                caseName: caseProjection.caseName,
                tagValue: caseProjection.tagValue,
                payloadValue: caseProjection.payloadValue,
                tagHex: String(format: "0x%02X", caseProjection.tagValue),
                payloadHex: String(format: "0x%02X", caseProjection.payloadValue),
                tagValueBinary: "0b\(String(caseProjection.tagValue, radix: 2))",
                payloadValueBinary: "0b\(String(caseProjection.payloadValue, radix: 2))",
                caseType: caseType,
                memoryChangeCount: caseProjection.memoryChanges.count,
                memoryChangesDetail: memoryChangesDetail
            )
            let header = module.transformCase(caseInput)
            let indentStr = String(repeating: "    ", count: indentation)
            var output = ""
            for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
                output += "\(indentStr)// \(line)\n"
            }
            if caseProjection.memoryChanges.isEmpty {
                output += "\(indentStr)// (No bits set / Zero)\n"
            } else {
                for offset in caseProjection.memoryChanges.keys.sorted() {
                    let byteValue = caseProjection.memoryChanges[offset]!
                    let offsetInput = Transformer.SwiftEnumLayout.MemoryOffsetInput(
                        offset: offset,
                        value: byteValue
                    )
                    let formattedOffset = module.transformMemoryOffset(offsetInput)
                    output += "\(indentStr)// \(formattedOffset)\n"
                }
            }
            return AtomicComponent(string: output, type: .comment).asSemanticString()
        }

        return (layoutTransformer, caseTransformer)
    }

    // MARK: - Object Enumeration

    func allObjects() async throws -> [RuntimeObject] {
        #log(.debug, "Getting all Swift objects")
        let rootTypeName = try indexer.rootTypeDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let rootProtocolName = try indexer.rootProtocolDefinitions.map { try makeRuntimeObject(for: $0.value, isChild: false) }
        let typeExtensionName = try indexer.typeExtensionDefinitions.filter { $0.key.typeName.map { indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeExtension($0.key)) }
        let protocolExtensionName = try indexer.protocolExtensionDefinitions.filter { $0.key.protocolName.map { indexer.allProtocolDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .protocolExtension($0.key)) }
        let typeAliasExtensionName = try indexer.typeAliasExtensionDefinitions.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftExtension, definitionName: .typeAliasExtension($0.key)) }
        let conformanceExtensionName = try indexer.conformanceExtensionDefinitions.filter { $0.key.typeName.map { indexer.allTypeDefinitions[$0] == nil } ?? false }.map { try makeRuntimeObject(for: $0.value, extensionName: $0.key, kind: $0.key.runtimeObjectKindOfSwiftConformance, definitionName: .conformance($0.key)) }
        let allObjects = rootTypeName + rootProtocolName + typeExtensionName + protocolExtensionName + typeAliasExtensionName + conformanceExtensionName
        #log(.debug, "Found \(allObjects.count, privacy: .public) Swift objects: \(rootTypeName.count, privacy: .public) types, \(rootProtocolName.count, privacy: .public) protocols, \(typeExtensionName.count, privacy: .public) type extensions")
        return allObjects
    }

    private func makeRuntimeObject(for extensionDefintions: [ExtensionDefinition], extensionName: ExtensionName, kind: RuntimeObjectKind, definitionName: InterfaceDefinitionName) throws -> RuntimeObject {
        let typeChildren = try extensionDefintions.flatMap { $0.types }.map { try makeRuntimeObject(for: $0, isChild: true) }
        let protocolChildren = try extensionDefintions.flatMap { $0.protocols }.map { try makeRuntimeObject(for: $0, isChild: true) }
        let mangledName = try mangleAsString(extensionName.node)
        let runtimeObjectName = RuntimeObject(name: mangledName, displayName: extensionName.name, kind: kind, secondaryKind: nil, imagePath: imagePath, children: typeChildren + protocolChildren)
        interfaceDefinitionNameByObject[runtimeObjectName] = definitionName
        return runtimeObjectName
    }

    private func makeRuntimeObject(for protocolDefintion: ProtocolDefinition, isChild: Bool) throws -> RuntimeObject {
        let mangledName = try mangleAsString(protocolDefintion.protocolName.node)
        let runtimeObjectName: RuntimeObject
        if isChild {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.currentName, kind: protocolDefintion.protocolName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: [])
            interfaceDefinitionNameByObject[runtimeObjectName] = .childProtocol(protocolDefintion.protocolName)
        } else {
            runtimeObjectName = RuntimeObject(name: mangledName, displayName: protocolDefintion.protocolName.name, kind: protocolDefintion.protocolName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: [])
            interfaceDefinitionNameByObject[runtimeObjectName] = .rootProtocol(protocolDefintion.protocolName)
        }
        return runtimeObjectName
    }

    private func makeRuntimeObject(for typeDefinition: TypeDefinition, isChild: Bool, unspecializedTypeName: SwiftInterface.TypeName? = nil) throws -> RuntimeObject {
        let typeChildren = try typeDefinition.typeChildren.map { try makeRuntimeObject(for: $0, isChild: true) }
        let protocolChildren = try typeDefinition.protocolChildren.map { try makeRuntimeObject(for: $0, isChild: true) }
        let specializedChildren = try typeDefinition.specializedChildren.map {
            try makeRuntimeObject(for: $0, isChild: true, unspecializedTypeName: typeDefinition.typeName)
        }
        let allChildren = typeChildren + protocolChildren + specializedChildren

        let mangledName = try mangleAsString(typeDefinition.typeName.node)
        var properties: RuntimeObject.Properties = []
        if typeDefinition.type.contextDescriptorWrapper.contextDescriptor.layout.flags.isGeneric {
            properties.insert(.isGeneric)
        }
        let isSpecialized = typeDefinition.isSpecialized
        if isSpecialized {
            properties.insert(.isSpecialized)
        }
        let displayName = isSpecialized ? typeDefinition.typeName.name(using: .interfaceTypeBuilderOnly.subtracting(.removeBoundGeneric)) : typeDefinition.typeName.name

        let runtimeObject = RuntimeObject(name: mangledName, displayName: displayName, kind: typeDefinition.typeName.runtimeObjectKind, secondaryKind: nil, imagePath: imagePath, children: allChildren, properties: properties)
        if isSpecialized, let unspecializedTypeName {
            interfaceDefinitionNameByObject[runtimeObject] = .specializedType(unspecialized: unspecializedTypeName, specialized: typeDefinition.typeName)
        } else if isChild {
            interfaceDefinitionNameByObject[runtimeObject] = .childType(typeDefinition.typeName)
        } else {
            interfaceDefinitionNameByObject[runtimeObject] = .rootType(typeDefinition.typeName)
        }
        return runtimeObject
    }

    func interface(for object: RuntimeObject) async throws -> RuntimeObjectInterface {
        #log(.debug, "Generating Swift interface for: \(object.displayName, privacy: .public)")
        if let interface = interfaceByObject[object] {
            #log(.debug, "Using cached interface")
            return interface
        }

        guard let interfaceDefinitionName = interfaceDefinitionNameByObject[object] else {
            #log(.default, "Invalid runtime object: \(object.displayName, privacy: .public)")
            throw Error.invalidRuntimeObject
        }
        var newInterfaceString: SemanticString = ""
        switch interfaceDefinitionName {
        case .specializedType(let unspecializedTypeName, let specializedTypeName):
            // The indexer keeps `allTypeDefinitions` keyed by the
            // unspecialized typeName; specialized children live on the
            // parent's `specializedChildren` array (per the upstream's
            // intentional decision to keep the indexer agnostic of
            // user-driven specialization). Look up the parent first, then
            // pick the specialized sibling whose bound `TypeName` matches.
            guard let parentDefinition = indexer.allTypeDefinitions[unspecializedTypeName],
                  let specializedDefinition = parentDefinition.specializedChildren.first(where: { $0.typeName == specializedTypeName })
            else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(printer.printTypeDefinition(specializedDefinition))
        case .rootType(let rootTypeName):
            guard let typeDefinition = indexer.rootTypeDefinitions[rootTypeName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(printer.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = indexer.typeExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = indexer.conformanceExtensionDefinitions[rootTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childType(let childTypeName):
            guard let typeDefinition = indexer.allTypeDefinitions[childTypeName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(printer.printTypeDefinition(typeDefinition))
            if let typeExtensionDefinitions = indexer.typeExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(typeExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let conformanceExtensionDefinitions = indexer.conformanceExtensionDefinitions[childTypeName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(conformanceExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .rootProtocol(let rootProtocolName):
            guard let definition = indexer.rootProtocolDefinitions[rootProtocolName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(printer.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = indexer.protocolExtensionDefinitions[rootProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .childProtocol(let childProtocolName):
            guard let definition = indexer.allProtocolDefinitions[childProtocolName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(printer.printProtocolDefinition(definition))
            if !definition.defaultImplementationExtensions.isEmpty {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(definition.defaultImplementationExtensions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
            if let protocolExtensionDefinitions = indexer.protocolExtensionDefinitions[childProtocolName.extensionName] {
                newInterfaceString.append(.doubleBreakLine)
                try await newInterfaceString.append(protocolExtensionDefinitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
            }
        case .typeExtension(let typeExtensionName):
            guard let definitions = indexer.typeExtensionDefinitions[typeExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .protocolExtension(let protocolExtensionName):
            guard let definitions = indexer.protocolExtensionDefinitions[protocolExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .typeAliasExtension(let typeAliasExtensionName):
            guard let definitions = indexer.typeAliasExtensionDefinitions[typeAliasExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        case .conformance(let conformanceExtensionName):
            guard let definitions = indexer.conformanceExtensionDefinitions[conformanceExtensionName] else { throw Error.invalidRuntimeObject }
            try await newInterfaceString.append(definitions.box.asyncMap { try await printer.printExtensionDefinition($0) }.join(separator: .doubleBreakLine))
        }

        let newInterface = RuntimeObjectInterface(object: object, interfaceString: newInterfaceString)
        interfaceByObject[object] = newInterface
        #log(.debug, "Interface generated and cached")
        return newInterface
    }

    func memberAddresses(for object: RuntimeObject, memberName: String?) async throws -> [RuntimeMemberAddress] {
        #log(.debug, "Getting member addresses for: \(object.displayName, privacy: .public)")
        // Ensure the definition is indexed by generating the interface (uses internal cache)
        _ = try? await interface(for: object)

        guard let definitionName = interfaceDefinitionNameByObject[object] else {
            #log(.debug, "No definition found for: \(object.displayName, privacy: .public)")
            return []
        }

        var result: [RuntimeMemberAddress] = []

        func shouldInclude(_ name: String) -> Bool {
            guard let filter = memberName else { return true }
            return name.lowercased().contains(filter.lowercased())
        }

        func collect(from definition: any Definition, prefix: String = "") {
            for funcDef in definition.functions where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "func",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO)
                    )
                )
            }
            for funcDef in definition.staticFunctions where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "static func",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO)
                    )
                )
            }
            for funcDef in definition.constructors where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "init",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO)
                    )
                )
            }
            for funcDef in definition.allocators where shouldInclude(funcDef.name) {
                result.append(
                    RuntimeMemberAddress(
                        name: funcDef.name,
                        kind: prefix + "allocator",
                        symbolName: funcDef.symbol.symbol.name,
                        address: funcDef.symbol.symbol.addressString(format: .hex, in: machO)
                    )
                )
            }
            for varDef in definition.variables where shouldInclude(varDef.name) {
                for accessor in varDef.accessors where accessor.kind != .none {
                    result.append(
                        RuntimeMemberAddress(
                            name: varDef.name,
                            kind: prefix + accessor.kind.kindString,
                            symbolName: accessor.symbol.symbol.name,
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO)
                        )
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
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO)
                        )
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
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO)
                        )
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
                            address: accessor.symbol.symbol.addressString(format: .hex, in: machO)
                        )
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
            if let parentDefinition = indexer.allTypeDefinitions[unspecializedTypeName],
               let specializedDefinition = parentDefinition.specializedChildren.first(where: { $0.typeName == specializedTypeName }) {
                collect(from: specializedDefinition)
            }
        case .rootProtocol(let protocolName),
             .childProtocol(let protocolName):
            if let protocolDefinition = indexer.allProtocolDefinitions[protocolName] {
                collect(from: protocolDefinition)
            }
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

    // MARK: - Generic Specialization

    func specializationRequest(for object: RuntimeObject) async throws -> RuntimeSpecializationRequest {
        do {
            let typeDefinition = try requireGenericTypeDefinition(for: object)
            let upstreamRequest = try specializer.makeRequest(for: typeDefinition.type.typeContextDescriptorWrapper)
            return try makeRuntimeSpecializationRequest(from: upstreamRequest)
        } catch let error as GenericSpecializer<MachOImage>.SpecializerError {
            throw Self.translate(error)
        }
    }

    /// Build an inner specialization request for a candidate the user picked
    /// to bind a generic outer parameter. `candidateID` is the mangled string
    /// `mangleAsString(typeName.node)` carried over the wire; we reverse-look
    /// it up in `factory.indexer.allTypeDefinitions` — the shared sub-indexer
    /// aggregate — so cross-image candidates (`Array`, `Dictionary` from
    /// stdlib) are resolvable from any image that triggered the outer flow.
    /// `imagePath` only feeds the diagnostic on miss; the actual definition
    /// might live in a different image once the aggregate is consulted.
    func specializationRequest(
        forCandidateID candidateID: String,
        in imagePath: String
    ) async throws -> RuntimeSpecializationRequest {
        var matchedDefinition: TypeDefinition?
        for (typeName, definition) in factory.indexer.allTypeDefinitions {
            guard let mangled = try? await mangleAsString(typeName.node) else { continue }
            if mangled == candidateID {
                matchedDefinition = definition
                break
            }
        }
        guard let typeDefinition = matchedDefinition else {
            throw RuntimeEngine.EngineError.unindexedCandidate(displayName: candidateID, imagePath: imagePath)
        }
        do {
            let upstreamRequest = try specializer.makeRequest(for: typeDefinition.type.typeContextDescriptorWrapper)
            return try makeRuntimeSpecializationRequest(from: upstreamRequest)
        } catch let error as GenericSpecializer<MachOImage>.SpecializerError {
            throw Self.translate(error)
        }
    }

    func specialize(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeObject {
        let baseTypeDefinition = try requireGenericTypeDefinition(for: object)
        let upstreamRequest = try specializer.makeRequest(for: baseTypeDefinition.type.typeContextDescriptorWrapper)
        let resolved = try resolveUpstreamArguments(selection.arguments, against: upstreamRequest)
        let upstreamSelection = SpecializationSelection(arguments: resolved.arguments)
        let result: SpecializationResult
        do {
            result = try specializer.specialize(upstreamRequest, with: upstreamSelection)
        } catch let error as GenericSpecializer<MachOImage>.SpecializerError {
            throw Self.translate(error)
        }
        // Collect concrete argument typeNodes in declaration order so the
        // upstream `specialize(...)` rewrites the new TypeDefinition's typeName
        // from `Type → Structure(Box)` to `Type → BoundGenericStructure(Type → Structure(Box), TypeList(Type → Structure(Int), …))`.
        // Order must follow `upstreamRequest.parameters`, not the dictionary's
        // arbitrary key order — `BoundGenericStructure`'s TypeList is positional.
        let typeArgumentNodes: [Node] = upstreamRequest.parameters.compactMap { parameter in
            resolved.nodesByParameter[parameter.name]
        }
        let specializedDefinition = try await baseTypeDefinition.specialize(
            with: result,
            typeArgumentNodes: typeArgumentNodes.count == upstreamRequest.parameters.count ? typeArgumentNodes : nil,
            in: machO
        )
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
            unspecializedTypeName: baseTypeDefinition.typeName
        )
        // Force the parent generic's interface to be re-rendered next time it
        // is requested so that any consumers iterating its
        // `specializedChildren` pick up the newly registered child.
        interfaceByObject.removeValue(forKey: object)
        return runtimeObject
    }

    func runtimePreflight(
        for object: RuntimeObject,
        with selection: RuntimeSpecializationSelection
    ) async throws -> RuntimeSpecializationValidation {
        let typeDefinition = try requireGenericTypeDefinition(for: object)
        let upstreamRequest = try specializer.makeRequest(for: typeDefinition.type.typeContextDescriptorWrapper)
        let resolved = try resolveUpstreamArguments(selection.arguments, against: upstreamRequest)
        let upstreamSelection = SpecializationSelection(arguments: resolved.arguments)
        let upstreamValidation = specializer.runtimePreflight(selection: upstreamSelection, for: upstreamRequest)
        return Self.translate(upstreamValidation)
    }

    private static func translate(_ validation: SpecializationValidation) -> RuntimeSpecializationValidation {
        RuntimeSpecializationValidation(
            isValid: validation.isValid,
            errors: validation.errors.map(translate(_:)),
            warnings: validation.warnings.map(translate(_:))
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
                actualType: actualType
            )
        case .layoutRequirementNotSatisfied(let parameterName, let expectedLayout, let actualType):
            return .layoutRequirementNotSatisfied(
                parameterName: parameterName,
                expectedLayout: String(describing: expectedLayout),
                actualType: actualType
            )
        case .baseClassRequirementNotSatisfied(let parameterName, let expectedBaseClass, let actualType):
            return .baseClassRequirementNotSatisfied(
                parameterName: parameterName,
                expectedBaseClass: expectedBaseClass,
                actualType: actualType
            )
        case .sameTypeRequirementNotSatisfied(let parameterName, let expectedType, let actualType):
            return .sameTypeRequirementNotSatisfied(
                parameterName: parameterName,
                expectedType: expectedType,
                actualType: actualType
            )
        case .metadataResolutionFailed(let parameterName, let reason):
            return .metadataResolutionFailed(parameterName: parameterName, reason: reason)
        case .protocolDescriptorResolutionFailed(let parameterName, let protocolName, let reason):
            return .protocolDescriptorResolutionFailed(
                parameterName: parameterName,
                protocolName: protocolName,
                reason: reason
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
        guard let definitionName = interfaceDefinitionNameByObject[object],
              let typeName = definitionName.typeName
        else {
            throw Error.invalidRuntimeObject
        }
        if let root = indexer.rootTypeDefinitions[typeName] { return root }
        if let any = indexer.allTypeDefinitions[typeName] { return any }
        throw Error.invalidRuntimeObject
    }

    /// Project the upstream `SpecializationRequest` into the public Codable
    /// `RuntimeSpecializationRequest` that crosses the wire.
    private func makeRuntimeSpecializationRequest(
        from upstream: SpecializationRequest
    ) throws -> RuntimeSpecializationRequest {
        let parameters = try upstream.parameters.map { upstreamParameter -> RuntimeSpecializationRequest.Parameter in
            let candidates = try upstreamParameter.candidates.map { upstreamCandidate -> RuntimeSpecializationRequest.Candidate in
                let id = try mangleAsString(upstreamCandidate.typeName.node)
                let imagePath: String
                switch upstreamCandidate.source {
                case .image(let path):
                    imagePath = path
                }
                return RuntimeSpecializationRequest.Candidate(
                    id: id,
                    displayName: upstreamCandidate.typeName.name,
                    imagePath: imagePath,
                    isGeneric: upstreamCandidate.isGeneric
                )
            }
            return RuntimeSpecializationRequest.Parameter(
                name: upstreamParameter.name,
                displayDescription: makeParameterDescription(upstreamParameter),
                candidates: candidates
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
    private static let maxSpecializationDepth = 16

    private func resolveUpstreamArguments(
        _ runtimeArguments: [String: RuntimeSpecializationSelection.Argument],
        against request: SpecializationRequest,
        depth: Int = 0
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
        depth: Int
    ) throws -> (argument: SpecializationSelection.Argument, node: Node) {
        switch runtimeArgument {
        case .candidate(let runtimeCandidate):
            let matched = try matchUpstreamCandidate(runtimeCandidate, in: parameter)
            return (.candidate(matched), matched.typeName.node)
        case .boundGeneric(let runtimeBase, let innerRuntimeArguments):
            guard depth < Self.maxSpecializationDepth else {
                throw RuntimeEngine.EngineError.boundGenericInnerFailed(
                    parameterName: parameter.name,
                    underlying: "Nested specialization depth exceeds the limit of \(Self.maxSpecializationDepth)."
                )
            }
            let matchedBase = try matchUpstreamCandidate(runtimeBase, in: parameter)
            guard let innerTypeDefinition = factory.indexer.allTypeDefinitions[matchedBase.typeName] else {
                throw RuntimeEngine.EngineError.unindexedCandidate(
                    displayName: runtimeBase.displayName,
                    imagePath: runtimeBase.imagePath
                )
            }
            let innerRequest: SpecializationRequest
            do {
                innerRequest = try specializer.makeRequest(for: innerTypeDefinition.type.typeContextDescriptorWrapper)
            } catch let error as GenericSpecializer<MachOImage>.SpecializerError {
                throw Self.translate(error)
            }
            let innerResolved = try resolveUpstreamArguments(
                innerRuntimeArguments,
                against: innerRequest,
                depth: depth + 1
            )
            let innerNodes: [Node] = innerRequest.parameters.compactMap { innerResolved.nodesByParameter[$0.name] }
            let boundNode = Self.buildBoundGenericNode(base: matchedBase, innerNodes: innerNodes)
            return (
                .boundGeneric(baseCandidate: matchedBase, innerArguments: innerResolved.arguments),
                boundNode
            )
        }
    }

    private func matchUpstreamCandidate(
        _ runtimeCandidate: RuntimeSpecializationRequest.Candidate,
        in parameter: SpecializationRequest.Parameter
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
            candidateDisplayName: runtimeCandidate.displayName
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
        innerNodes: [Node]
    ) -> Node {
        let boundKind: Node.Kind
        switch base.typeName.kind {
        case .struct: boundKind = .boundGenericStructure
        case .class: boundKind = .boundGenericClass
        case .enum: boundKind = .boundGenericEnum
        }
        let baseNode = wrappedAsType(base.typeName.node)
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
    private static func translate(_ error: GenericSpecializer<MachOImage>.SpecializerError) -> Swift.Error {
        switch error {
        case .notGenericType:
            return RuntimeEngine.EngineError.typeNotGeneric
        case .unsupportedGenericParameter:
            return RuntimeEngine.EngineError.unsupportedGenericParameter(description: error.localizedDescription)
        case .boundGenericInnerFailed(let parameterName, let underlying):
            return RuntimeEngine.EngineError.boundGenericInnerFailed(
                parameterName: parameterName,
                underlying: (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)"
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
            case .protocol(let info):
                conformanceTokens.append(info.protocolName.name)
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

    func classHierarchy(for object: RuntimeObject) async throws -> [String] {
        #log(.debug, "Getting Swift class hierarchy for: \(object.displayName, privacy: .public)")
        guard case .swift(.type(.class)) = object.kind,
              let classDefinitionName = interfaceDefinitionNameByObject[object]?.typeName,
              let classDefinition = indexer.allTypeDefinitions[classDefinitionName],
              case .class(let `class`) = classDefinition.type
        else {
            #log(.debug, "No class hierarchy found")
            return []
        }
        let hierarchy = try ClassHierarchyDumper(machO: machO).dump(for: `class`.descriptor)
        #log(.debug, "Class hierarchy: \(hierarchy.count, privacy: .public) levels")
        return hierarchy
    }
    
    fileprivate func setupForFactory(_ factory: RuntimeSwiftSectionFactory) {
        factory.indexer.addSubIndexer(indexer)
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

@Loggable(.private)
actor RuntimeSwiftSectionFactory {
    
    let indexer: SwiftInterfaceIndexer<MachOImage>
    
    private var sections: [String: RuntimeSwiftSection] = [:]

    init() {
        indexer = .init(configuration: .init(), eventHandlers: [], in: .current())
    }
    
    func existingSection(for imagePath: String) -> RuntimeSwiftSection? {
        sections[imagePath]
    }

    func hasCachedSection(for path: String) -> Bool {
        sections[path] != nil
    }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation? = nil) async throws -> (isExisted: Bool, section: RuntimeSwiftSection) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached Swift section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        #log(.debug, "Creating Swift section for: \(imagePath, privacy: .public)")
        let section = try await RuntimeSwiftSection(imagePath: imagePath, factory: self, progressContinuation: progressContinuation)
        sections[imagePath] = section
        await section.setupForFactory(self)
        #log(.debug, "Swift section created and cached")
        return (false, section)
    }

    func removeSection(for imagePath: String) {
        sections.removeValue(forKey: imagePath)
    }

    func removeAllSections() {
        sections.removeAll()
    }
}

@FrameworkToolboxExtension(.internal)
extension SwiftInterface.Definition {}

extension SwiftInterface.AccessorKind {
    fileprivate var kindString: String {
        switch self {
        case .getter: return "getter"
        case .setter: return "setter"
        case .modifyAccessor: return "modifyAccessor"
        case .readAccessor: return "readAccessor"
        case .none: return "none"
        }
    }
}
