import Foundation
import FoundationToolbox
import CPlusPlusSymbols

/// The C++ sections of an engine's images, built when first asked for.
///
/// Shaped like `RuntimeObjCSectionFactory`: a section per image, keyed by the
/// catalog's canonical path, and one build per image that every request for
/// it waits on (`RuntimeSectionBuild`). Nothing in it is part of an image
/// being indexed — see `RuntimeCPlusPlusSectionProviding`.
@Loggable(.private)
actor RuntimeCPlusPlusSectionFactory<Reading: RuntimeImageReading>: RuntimeCPlusPlusSectionProviding {
    typealias MachO = Reading.MachO

    enum Error: Swift.Error {
        case imageNotFound
    }

    /// Where the images behind the sections come from.
    let catalog: any RuntimeImageCatalog<Reading>

    /// Per-image sections, keyed by the catalog's canonical image path.
    private var sections: [String: RuntimeCPlusPlusSection<Reading>] = [:]

    /// Builds under way, keyed like `sections`.
    private var sectionBuilds: [String: RuntimeSectionBuild<RuntimeCPlusPlusSection<Reading>>] = [:]

    /// The images the stores were asked about through a section, so that
    /// `removeAllSections()` drops what the stores keep for them.
    private var machOsByImagePath: [String: MachO] = [:]

    init(catalog: any RuntimeImageCatalog<Reading>) {
        self.catalog = catalog
    }

    func existingSection(for imagePath: String) -> RuntimeCPlusPlusSection<Reading>? {
        sections[imagePath]
    }

    func section(for imagePath: String, progressContinuation: LoadingEventContinuation?) async throws -> (isExisted: Bool, section: RuntimeCPlusPlusSection<Reading>) {
        if let section = sections[imagePath] {
            return (true, section)
        }
        let catalog = catalog
        let section = try await sectionBuild(for: imagePath) { relayContinuation in
            guard let machO = catalog.machO(forImagePath: imagePath) else {
                throw Error.imageNotFound
            }
            return (machO, RuntimeCPlusPlusSection<Reading>(
                imagePath: imagePath,
                machO: machO,
                dependencySearchPaths: catalog.dependencySearchPaths(forImageAt: imagePath),
                progressContinuation: relayContinuation
            ))
        }
        .section(forwardingProgressTo: progressContinuation)
        return (false, section)
    }

    func section(definingClassWithMangledTypeName mangledTypeName: String) async throws -> RuntimeCPlusPlusSection<Reading>? {
        guard let (imagePath, machO) = await catalog.image(definingCPlusPlusTypeInfoForMangledTypeName: mangledTypeName) else {
            #log(.debug, "No image exports the typeinfo of \(mangledTypeName, privacy: .public)")
            return nil
        }
        if let section = sections[imagePath] {
            return section
        }
        let catalog = catalog
        return try await sectionBuild(for: imagePath) { relayContinuation in
            (machO, RuntimeCPlusPlusSection<Reading>(
                imagePath: imagePath,
                machO: machO,
                dependencySearchPaths: catalog.dependencySearchPaths(forImageAt: imagePath),
                progressContinuation: relayContinuation
            ))
        }
        .section(forwardingProgressTo: nil)
    }

    /// The build under way for `imagePath`, starting one when there is none.
    /// The finished section is registered from inside the build, before any
    /// waiter is released.
    private func sectionBuild(
        for imagePath: String,
        makingSectionWith makeSection: @escaping @Sendable (LoadingEventContinuation) async throws -> (MachO, RuntimeCPlusPlusSection<Reading>)
    ) -> RuntimeSectionBuild<RuntimeCPlusPlusSection<Reading>> {
        if let sectionBuild = sectionBuilds[imagePath] {
            return sectionBuild
        }
        #log(.debug, "Creating C++ section for: \(imagePath, privacy: .public)")
        let sectionBuild = RuntimeSectionBuild<RuntimeCPlusPlusSection<Reading>> { [self] relayContinuation in
            do {
                let (machO, section) = try await makeSection(relayContinuation)
                await registerBuiltSection(section, machO: machO, for: imagePath)
                return section
            } catch {
                await discardSectionBuild(for: imagePath)
                throw error
            }
        }
        sectionBuilds[imagePath] = sectionBuild
        return sectionBuild
    }

    private func registerBuiltSection(_ section: RuntimeCPlusPlusSection<Reading>, machO: MachO, for imagePath: String) {
        sections[imagePath] = section
        machOsByImagePath[imagePath] = machO
        sectionBuilds[imagePath] = nil
    }

    private func discardSectionBuild(for imagePath: String) {
        sectionBuilds[imagePath] = nil
    }

    /// Drops every section and what the two stores keep for their images.
    /// Indexes the stores built of other images while naming a slot through
    /// a base there stay in the stores' own caches: which images those were,
    /// the stores do not say.
    func removeAllSections() {
        for machO in machOsByImagePath.values {
            CPlusPlusClassIndexStore.shared.remove(for: machO)
            CPlusPlusSymbolIndexStore.shared.remove(for: machO)
        }
        machOsByImagePath.removeAll()
        sections.removeAll()
    }
}
