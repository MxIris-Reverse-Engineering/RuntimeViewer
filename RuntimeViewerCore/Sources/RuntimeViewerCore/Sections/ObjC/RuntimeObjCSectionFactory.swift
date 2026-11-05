import Foundation
import FoundationToolbox
import MachOObjCSection
import ObjCDump
import ObjCTypeDecodeKit
import OrderedCollections
private import RuntimeViewerObjC
import Semantic
import SwiftInspection
import Utilities
import MetaCodable

import ObjCDeclarationRendering
import ObjCIndexing
import ObjCInterface

@Loggable(.private)
actor RuntimeObjCSectionFactory<Reading: RuntimeImageReading>: RuntimeObjCSectionProviding {
    typealias MachO = Reading.MachO
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
    /// fan queries out across `subIndexers`. Its image is a placeholder for the
    /// same reason it is on the Swift side.
    let indexer: RuntimeObjCInterfaceIndexer<Reading>

    /// Where the images behind the sections come from.
    let catalog: any RuntimeImageCatalog<Reading>

    /// Per-image sections, keyed by the catalog's canonical image path.
    private var sections: [String: RuntimeObjCSection<Reading>] = [:]

    /// Builds under way, keyed like `sections`. A request for an image that is
    /// being built waits for that build instead of starting a second one; see
    /// `RuntimeSectionBuild`.
    private var sectionBuilds: [String: RuntimeSectionBuild<RuntimeObjCSection<Reading>>] = [:]

    /// `placeholderImage` stands behind the aggregate indexer, which parses no
    /// image of its own; any image of the catalog will do.
    init(catalog: any RuntimeImageCatalog<Reading>, placeholderImage: MachO) {
        self.catalog = catalog
        self.indexer = RuntimeObjCInterfaceIndexer<Reading>(machO: placeholderImage, imagePath: "")
    }

    func existingSection(for imagePath: String) -> RuntimeObjCSection<Reading>? {
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

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: RuntimeObjCSection<Reading>) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached ObjC section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        let catalog = catalog
        let section = try await sectionBuild(for: imagePath) { factory, relayContinuation in
            guard let machO = catalog.machO(forImagePath: imagePath) else {
                throw RuntimeObjCSection<Reading>.Error.imageNotFound
            }
            return try await RuntimeObjCSection(imagePath: imagePath, machO: machO, factory: factory, progressContinuation: relayContinuation)
        }
        .section(forwardingProgressTo: progressContinuation)
        return (false, section)
    }

    func section(for name: RuntimeObjCName) async throws -> RuntimeObjCSection<Reading>? {
        #log(.debug, "Looking up ObjC section for name: \(String(describing: name), privacy: .public)")
        do {
            guard let (imagePath, machO) = await catalog.image(definingObjCType: name) else {
                #log(.debug, "No image found for name")
                return nil
            }

            if let existObjCSection = sections[imagePath] {
                #log(.debug, "Using cached ObjC section")
                return existObjCSection
            }

            return try await sectionBuild(for: imagePath) { factory, relayContinuation in
                try await RuntimeObjCSection(imagePath: imagePath, machO: machO, factory: factory, progressContinuation: relayContinuation)
            }
            .section(forwardingProgressTo: nil)
        } catch {
            #log(.error, "Failed to create ObjC section: \(error, privacy: .public)")
            return nil
        }
    }

    /// The build under way for `imagePath`, starting one when there is none.
    ///
    /// The finished section is registered from inside the build, before any
    /// waiter is released, so every waiter returns a section that is already
    /// cached and attached to the aggregate. A build that fails leaves nothing
    /// behind, and the next request starts afresh.
    private func sectionBuild(
        for imagePath: String,
        makingSectionWith makeSection: @escaping @Sendable (RuntimeObjCSectionFactory<Reading>, LoadingEventContinuation) async throws -> RuntimeObjCSection<Reading>
    ) -> RuntimeSectionBuild<RuntimeObjCSection<Reading>> {
        if let sectionBuild = sectionBuilds[imagePath] {
            #log(.debug, "Joining the ObjC section build under way for: \(imagePath, privacy: .public)")
            return sectionBuild
        }
        #log(.debug, "Creating ObjC section for: \(imagePath, privacy: .public)")
        let sectionBuild = RuntimeSectionBuild<RuntimeObjCSection<Reading>> { [self] relayContinuation in
            do {
                let section = try await makeSection(self, relayContinuation)
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

    private func registerBuiltSection(_ section: RuntimeObjCSection<Reading>, for imagePath: String) {
        sections[imagePath] = section
        indexer.addSubIndexer(section.objcIndexer)
        sectionBuilds[imagePath] = nil
        #log(.debug, "ObjC section created and cached")
    }

    private func discardSectionBuild(for imagePath: String) {
        sectionBuilds[imagePath] = nil
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

extension RuntimeObjCSectionFactory where Reading == RuntimeLoadedImageReading {
    /// The factory over the images dyld loaded into this process.
    init() {
        self.init(catalog: RuntimeProcessImageCatalog(), placeholderImage: .current())
    }
}
