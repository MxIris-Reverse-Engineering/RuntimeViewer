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
actor RuntimeSwiftSectionFactory<Reading: RuntimeImageReading>: RuntimeSwiftSectionProviding {
    typealias MachO = Reading.MachO
    /// The originating typeName, the indexed entry and the key of the section
    /// that registered it, produced by
    /// `RuntimeSwiftSection.candidateIDMapping()`. The typeName is preserved
    /// so the eventual `EngineError.unindexedCandidate` (and any internal
    /// logging) can surface a human-readable name even when the lookup is
    /// driven by the opaque mangled candidate ID.
    ///
    /// `imagePath` is how a jump finds the defining section. The entry's image
    /// cannot be asked: a file names itself by its install name, which is not
    /// the path its sections are keyed by, and neither is an `@rpath` name
    /// dyld reports for an image it loaded.
    typealias IndexedTypeEntry = (
        typeName: SwiftDeclaration.TypeName,
        entry: MachOIndexedValue<MachO, TypeDefinition>,
        imagePath: String,
    )

    /// The originating protocolName, the defining image and its section's
    /// key, produced by `RuntimeSwiftSection.protocolCandidateIDMapping()`.
    /// `protocolName` is kept symmetric with `IndexedTypeEntry` for
    /// diagnostics.
    typealias IndexedProtocolEntry = (
        protocolName: SwiftDeclaration.ProtocolName,
        machO: MachO,
        imagePath: String,
    )

    let indexer: RuntimeSwiftInterfaceIndexer<Reading>

    /// Where the images behind the sections come from.
    let catalog: any RuntimeImageCatalog<Reading>

    /// The index configuration of every Swift indexer this factory makes —
    /// each section's own and the aggregate. Fixed for the indexer's lifetime;
    /// see `RuntimeSwiftSection.indexConfiguration(dependencySearchPaths:)`.
    nonisolated let indexConfiguration: SwiftDeclarationIndexConfiguration

    /// Where the static field layout of an image read from a file finds the
    /// images its fields' types come from.
    nonisolated let staticLayoutDependencyResolution: StaticLayoutDependencyResolution

    private var sections: [String: RuntimeSwiftSection<Reading>] = [:]

    /// Builds under way, keyed like `sections`. A request for an image that is
    /// being built waits for that build instead of starting a second one; see
    /// `RuntimeSectionBuild`.
    private var sectionBuilds: [String: RuntimeSectionBuild<RuntimeSwiftSection<Reading>>] = [:]

    /// Cross-image mangled candidate ID → indexed type, populated as each
    /// section registers. Replaces the prior O(n) walk over
    /// `indexer.allAllTypeDefinitions` (which re-mangled every typeName on
    /// every inner-request fetch) with an O(1) dictionary lookup.
    ///
    /// First-write-wins, mirroring `allAllTypeDefinitions`'s `result.merge(... { current, _ in current })`
    /// merge strategy: when stdlib types appear in multiple loaded
    /// dylibs (e.g. interposed builds), the section that registered first
    /// owns the canonical entry.
    private var indexedTypeByCandidateID: [String: IndexedTypeEntry] = [:]

    /// Cross-image protocol mangled name → defining image, kept separate from
    /// `indexedTypeByCandidateID` so a protocol candidate never masks a
    /// nominal-type candidate consumed by generic specialization. Same
    /// first-write-wins, per-image-eviction lifecycle as the type table.
    private var indexedProtocolByCandidateID: [String: IndexedProtocolEntry] = [:]

    /// The runtime name of an Objective-C protocol → the image that declares
    /// it as an `@objc` protocol in Swift, populated as each section
    /// registers, keyed like `sections`. The copy another image holds of such
    /// a protocol finds its Swift face through it
    /// (`RuntimeEngine.counterpart(for:)`). First write wins, and an image's
    /// entries leave with its section, as in the candidate tables.
    private var declaringImagePathByObjCProtocolName: [String: String] = [:]

    /// `placeholderImage` stands behind the aggregate indexer, which parses no
    /// image of its own; any image of the catalog will do.
    init(catalog: any RuntimeImageCatalog<Reading>, placeholderImage: MachO) {
        let dependencySearchPaths = catalog.dependencySearchPaths
        let indexConfiguration = RuntimeSwiftSection<Reading>.indexConfiguration(dependencySearchPaths: dependencySearchPaths)
        self.catalog = catalog
        self.indexConfiguration = indexConfiguration
        self.staticLayoutDependencyResolution = .dependencyClosure(searchPaths: dependencySearchPaths)
        self.indexer = RuntimeSwiftInterfaceIndexer<Reading>(machO: placeholderImage, imagePath: "", configuration: indexConfiguration)
    }

    func existingSection(for imagePath: String) -> RuntimeSwiftSection<Reading>? {
        sections[imagePath]
    }

    func hasCachedSection(for path: String) -> Bool {
        sections[path] != nil
    }

    /// Every image path with a cached `RuntimeSwiftSection` — the canonical
    /// (dyld-patched) keys under which `section(for:)` registered them.
    /// See `RuntimeObjCSectionFactory.cachedImagePaths`; the resolver
    /// intersects the two to obtain every fully-indexed image.
    var cachedImagePaths: Set<String> {
        Set(sections.keys)
    }

    /// O(1) lookup of the indexed type backing a `candidateID` (the mangled
    /// string carried over the wire by `RuntimeSpecializationRequest.Candidate.id`).
    /// Returns `nil` if the candidate's defining image has not been indexed
    /// — typically a candidate from an image that was unloaded between
    /// request and selection.
    func indexedType(forCandidateID candidateID: String) -> IndexedTypeEntry? {
        indexedTypeByCandidateID[candidateID]
    }

    /// O(1) lookup of the protocol backing a mangled protocol-name string.
    /// Returns `nil` when the protocol's defining image is not indexed.
    func indexedProtocol(forCandidateID candidateID: String) -> IndexedProtocolEntry? {
        indexedProtocolByCandidateID[candidateID]
    }

    /// The image that declares the `@objc` protocol an Objective-C protocol
    /// record of `runtimeName` belongs to, among the images indexed right now.
    func imagePath(declaringObjCProtocolNamed runtimeName: String) -> String? {
        declaringImagePathByObjCProtocolName[runtimeName]
    }

    func imagePath(definingTypeWithCandidateID candidateID: String) -> String? {
        indexedTypeByCandidateID[candidateID]?.imagePath
    }

    func imagePath(definingProtocolWithCandidateID candidateID: String) -> String? {
        indexedProtocolByCandidateID[candidateID]?.imagePath
    }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: RuntimeSwiftSection<Reading>) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached Swift section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        let section = try await sectionBuild(for: imagePath).section(forwardingProgressTo: progressContinuation)
        return (false, section)
    }

    /// The build under way for `imagePath`, starting one when there is none.
    ///
    /// The finished section is registered — cached, set up and its candidate
    /// IDs recorded — from inside the build, before any waiter is released. A
    /// build that fails leaves nothing behind, and the next request starts
    /// afresh.
    private func sectionBuild(for imagePath: String) -> RuntimeSectionBuild<RuntimeSwiftSection<Reading>> {
        if let sectionBuild = sectionBuilds[imagePath] {
            #log(.debug, "Joining the Swift section build under way for: \(imagePath, privacy: .public)")
            return sectionBuild
        }
        #log(.debug, "Creating Swift section for: \(imagePath, privacy: .public)")
        let catalog = catalog
        let sectionBuild = RuntimeSectionBuild<RuntimeSwiftSection<Reading>> { [self] relayContinuation in
            do {
                guard let machO = catalog.machO(forImagePath: imagePath) else {
                    #log(.error, "No image to build a Swift section for: \(imagePath, privacy: .public)")
                    throw RuntimeSwiftSection<Reading>.Error.imageNotFound
                }
                let section = try await RuntimeSwiftSection(imagePath: imagePath, machO: machO, factory: self, progressContinuation: relayContinuation)
                await registerBuiltSection(section, for: imagePath)
                return section
            } catch {
                await discardSectionBuild(for: imagePath)
                throw error
            }
        }
        sectionBuilds[imagePath] = sectionBuild
        return sectionBuild
    }

    private func registerBuiltSection(_ section: RuntimeSwiftSection<Reading>, for imagePath: String) async {
        sections[imagePath] = section
        sectionBuilds[imagePath] = nil
        await section.setupForFactory(self)
        await registerCandidateIDs(from: section)
        for runtimeName in await section.objcProtocolRuntimeNames() where declaringImagePathByObjCProtocolName[runtimeName] == nil {
            declaringImagePathByObjCProtocolName[runtimeName] = imagePath
        }
        #log(.debug, "Swift section created and cached")
    }

    private func discardSectionBuild(for imagePath: String) {
        sectionBuilds[imagePath] = nil
    }

    /// Drop an image's section, detaching its indexer from the aggregate first.
    ///
    /// The detach is what actually frees memory: `indexer` outlives every
    /// section, so dropping the `sections` entry alone leaves the image's whole
    /// declaration graph reachable through `indexer.subIndexers`. See
    /// `RuntimeSwiftInterfaceIndexer.removeSubIndexer(_:)`.
    func removeSection(for imagePath: String) {
        if let section = sections.removeValue(forKey: imagePath) {
            indexer.removeSubIndexer(section.indexer)
        }
        // Drop any mangledID entries originating from this image so a
        // subsequent `addSubIndexer`-driven re-register can repopulate them.
        indexedTypeByCandidateID = indexedTypeByCandidateID.filter { _, value in
            value.imagePath != imagePath
        }
        indexedProtocolByCandidateID = indexedProtocolByCandidateID.filter { _, value in
            value.imagePath != imagePath
        }
        declaringImagePathByObjCProtocolName = declaringImagePathByObjCProtocolName.filter { _, declaringImagePath in
            declaringImagePath != imagePath
        }
    }

    func removeAllSections() {
        for section in sections.values {
            indexer.removeSubIndexer(section.indexer)
        }
        sections.removeAll()
        indexedTypeByCandidateID.removeAll()
        indexedProtocolByCandidateID.removeAll()
        declaringImagePathByObjCProtocolName.removeAll()
    }

    private func registerCandidateIDs(from section: RuntimeSwiftSection<Reading>) async {
        let mapping = await section.candidateIDMapping()
        for (id, value) in mapping {
            if indexedTypeByCandidateID[id] == nil {
                indexedTypeByCandidateID[id] = value
            }
        }
        let protocolMapping = await section.protocolCandidateIDMapping()
        for (id, value) in protocolMapping {
            if indexedProtocolByCandidateID[id] == nil {
                indexedProtocolByCandidateID[id] = value
            }
        }
    }
}

extension RuntimeSwiftSectionFactory where Reading == RuntimeLoadedImageReading {
    /// The factory over the images dyld loaded into this process.
    init() {
        self.init(catalog: RuntimeProcessImageCatalog(), placeholderImage: .current())
    }
}
