import Foundation
import Testing
@testable import RuntimeViewerCore

/// The cleanup a serving process does at its first use of derived data, and
/// the measuring and deleting the app does.
@Suite("RuntimeDerivedDataMaintenance")
struct RuntimeDerivedDataMaintenanceTests {
    private static let day: TimeInterval = 24 * 60 * 60

    /// A layout with one producer of the current system: directories made
    /// as the store makes them, dates set by the test.
    private struct Layout {
        let directory: DerivedDataTestDirectory
        let fileManager = FileManager.default

        var rootURL: URL {
            directory.location().rootURL
        }

        func systemURL(_ system: RuntimeDerivedDataSystemIdentity = DerivedDataTestIdentities.system) -> URL {
            rootURL.appendingPathComponent(system.directoryName, isDirectory: true)
        }

        /// A producer directory with a `LastUsed` of `lastUse`, or none.
        @discardableResult
        func producer(named name: String, in systemURL: URL, lastUse: Date?) throws -> URL {
            let producerURL = systemURL.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: producerURL.appendingPathComponent("Images/libobjc.A.dylib-0123456789ab"), withIntermediateDirectories: true)
            if let lastUse {
                let lastUsedURL = producerURL.appendingPathComponent("LastUsed")
                fileManager.createFile(atPath: lastUsedURL.path, contents: nil)
                try fileManager.setModificationDate(lastUse, of: lastUsedURL)
            }
            return producerURL
        }

        func imageDirectory(of producerURL: URL) -> URL {
            producerURL.appendingPathComponent("Images/libobjc.A.dylib-0123456789ab", isDirectory: true)
        }

        func cleanUp(now: Date = Date(), isProcessRunning: @escaping (RuntimeDerivedDataReadingMarker) -> Bool = { _ in false }) {
            RuntimeDerivedDataMaintenance.cleanUp(
                rootURL: rootURL,
                currentSystemDirectoryName: DerivedDataTestIdentities.system.directoryName,
                currentOperatingSystemBuild: DerivedDataTestIdentities.system.operatingSystemBuild,
                currentProducerDirectoryName: DerivedDataTestIdentities.producer.directoryName,
                now: now,
                isProcessRunning: isProcessRunning
            )
        }

        func exists(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.path)
        }
    }

    @Test("A system directory of another build goes; one of this build with another shared cache stays")
    func systemDirectories() throws {
        let layout = Layout(directory: try DerivedDataTestDirectory())
        let current = DerivedDataTestIdentities.system
        let otherBuild = RuntimeDerivedDataSystemIdentity(platform: .macOS, operatingSystemVersion: "27.1", operatingSystemBuild: "26A5000a", sharedCacheUUID: UUID())
        let otherSharedCache = RuntimeDerivedDataSystemIdentity(platform: .macOS, operatingSystemVersion: current.operatingSystemVersion, operatingSystemBuild: current.operatingSystemBuild, sharedCacheUUID: UUID())
        let catalyst = RuntimeDerivedDataSystemIdentity(platform: .macCatalyst, operatingSystemVersion: current.operatingSystemVersion, operatingSystemBuild: current.operatingSystemBuild, sharedCacheUUID: current.sharedCacheUUID)
        for system in [current, otherBuild, otherSharedCache, catalyst] {
            try layout.producer(named: DerivedDataTestIdentities.producer.directoryName, in: layout.systemURL(system), lastUse: Date())
        }
        let foreignURL = layout.rootURL.appendingPathComponent("NotASystem", isDirectory: true)
        try layout.fileManager.createDirectory(at: foreignURL, withIntermediateDirectories: true)

        layout.cleanUp()
        #expect(layout.exists(layout.systemURL(current)))
        #expect(!layout.exists(layout.systemURL(otherBuild)))
        #expect(layout.exists(layout.systemURL(otherSharedCache)))
        #expect(layout.exists(layout.systemURL(catalyst)))
        #expect(!layout.exists(foreignURL))
    }

    @Test("A producer unused for 14 days goes; this process's own and a recently used one stay")
    func producerDirectories() throws {
        let layout = Layout(directory: try DerivedDataTestDirectory())
        let now = Date()
        let systemURL = layout.systemURL()
        let own = try layout.producer(named: DerivedDataTestIdentities.producer.directoryName, in: systemURL, lastUse: now.addingTimeInterval(-40 * Self.day))
        let recent = try layout.producer(named: "aaaaaaaaaaaaaaaa", in: systemURL, lastUse: now.addingTimeInterval(-13 * Self.day))
        let stale = try layout.producer(named: "bbbbbbbbbbbbbbbb", in: systemURL, lastUse: now.addingTimeInterval(-15 * Self.day))
        let withoutLastUsed = try layout.producer(named: "cccccccccccccccc", in: systemURL, lastUse: nil)
        try layout.fileManager.setModificationDate(now.addingTimeInterval(-20 * Self.day), of: withoutLastUsed)

        layout.cleanUp(now: now)
        #expect(layout.exists(own), "never this process's own")
        #expect(layout.exists(recent))
        #expect(!layout.exists(stale))
        #expect(!layout.exists(withoutLastUsed), "the directory's own date stands in for a missing LastUsed")
    }

    @Test("Two builds used in turn, and one that keeps running, keep each other's data")
    func buildsInTurn() async throws {
        let directory = try DerivedDataTestDirectory()
        let layout = Layout(directory: directory)
        let section = RuntimeDerivedDataContainer.SectionIdentifier(rawValue: 1)
        var builder = RuntimeDerivedDataContainer.Builder()
        builder.append(Data("corpus".utf8), as: section)

        // The first build writes, and is then not launched for ten days.
        let first = DerivedDataTestIdentities.store(in: directory, producer: DerivedDataTestIdentities.otherProducer)
        await first.store(builder, as: .interfaceCorpus, variant: "A", forImageAt: "/usr/lib/libobjc.A.dylib")
        let firstLastUsedURL = first.producerDirectoryURL.appendingPathComponent("LastUsed")
        try layout.fileManager.setModificationDate(Date().addingTimeInterval(-10 * Self.day), of: firstLastUsedURL)

        // The second, launched now, cleans up at its first use.
        let second = DerivedDataTestIdentities.store(in: directory, cleansUpOnFirstUse: true)
        await second.store(builder, as: .interfaceCorpus, variant: "A", forImageAt: "/usr/lib/libobjc.A.dylib")
        await second.waitForCleanup()
        #expect(layout.exists(first.producerDirectoryURL))

        // Run long enough, the first one's data goes — unless it refreshes.
        let later = Date().addingTimeInterval(5 * Self.day)
        layout.cleanUp(now: later)
        #expect(!layout.exists(first.producerDirectoryURL))
    }

    @Test("Leftovers go: a renamed root, an old temporary file, an old marker of a dead read with its container")
    func leftovers() throws {
        let layout = Layout(directory: try DerivedDataTestDirectory())
        let now = Date()
        let producerURL = try layout.producer(named: DerivedDataTestIdentities.producer.directoryName, in: layout.systemURL(), lastUse: now)
        let imageURL = layout.imageDirectory(of: producerURL)
        let fileManager = layout.fileManager

        let renamedRootURL = layout.rootURL.deletingLastPathComponent().appendingPathComponent("DerivedData.deleting-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: renamedRootURL.appendingPathComponent("inside"), withIntermediateDirectories: true)

        let oldTemporaryURL = imageURL.appendingPathComponent(".InterfaceCorpus-A.rvdd.tmp-\(UUID().uuidString)")
        let freshTemporaryURL = imageURL.appendingPathComponent(".InterfaceCorpus-B.rvdd.tmp-\(UUID().uuidString)")
        let deadContainerURL = imageURL.appendingPathComponent("InterfaceCorpus-C.rvdd")
        let deadMarkerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: deadContainerURL)
        let liveContainerURL = imageURL.appendingPathComponent("InterfaceCorpus-D.rvdd")
        let liveMarkerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: liveContainerURL)
        let freshDeadContainerURL = imageURL.appendingPathComponent("InterfaceCorpus-E.rvdd")
        let freshDeadMarkerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: freshDeadContainerURL)
        for url in [oldTemporaryURL, freshTemporaryURL, deadContainerURL, liveContainerURL, freshDeadContainerURL] {
            fileManager.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        try RuntimeDerivedDataReadingMarker(processIdentifier: 1001, processStartTime: 1).write(to: deadMarkerURL)
        try RuntimeDerivedDataReadingMarker(processIdentifier: 1002, processStartTime: 1).write(to: liveMarkerURL)
        try RuntimeDerivedDataReadingMarker(processIdentifier: 1003, processStartTime: 1).write(to: freshDeadMarkerURL)
        for url in [oldTemporaryURL, deadContainerURL, deadMarkerURL, liveContainerURL, liveMarkerURL] {
            try fileManager.setModificationDate(now.addingTimeInterval(-2 * Self.day), of: url)
        }

        layout.cleanUp(now: now) { $0.processIdentifier == 1002 }
        #expect(!layout.exists(renamedRootURL))
        #expect(!layout.exists(oldTemporaryURL))
        #expect(layout.exists(freshTemporaryURL))
        #expect(!layout.exists(deadContainerURL))
        #expect(!layout.exists(deadMarkerURL))
        #expect(layout.exists(liveContainerURL))
        #expect(layout.exists(liveMarkerURL))
        #expect(layout.exists(freshDeadContainerURL), "a recent marker is left to the next read of its file")
        #expect(layout.exists(freshDeadMarkerURL))
    }

    @Test("Deleting renames the root aside at once and removes it")
    func deleteAll() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        var builder = RuntimeDerivedDataContainer.Builder()
        builder.append(Data(String(repeating: "corpus ", count: 1000).utf8), as: .init(rawValue: 1))
        await store.store(builder, as: .interfaceCorpus, variant: "A", forImageAt: "/usr/lib/libobjc.A.dylib")
        let location = directory.location()
        #expect(RuntimeDerivedDataMaintenance.allocatedByteCount(at: location) > 0)

        try RuntimeDerivedDataMaintenance.deleteAll(at: location)
        #expect(!FileManager.default.fileExists(atPath: location.rootURL.path))
        #expect(RuntimeDerivedDataMaintenance.allocatedByteCount(at: location) == 0)
        let parentURL = location.rootURL.deletingLastPathComponent()
        for _ in 0 ..< 100 {
            let leftNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
            if leftNames.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parentURL.path).isEmpty)

        // A later write makes the root again.
        await store.store(builder, as: .interfaceCorpus, variant: "A", forImageAt: "/usr/lib/libobjc.A.dylib")
        #expect(FileManager.default.fileExists(atPath: location.rootURL.path))
    }

    @Test("Deleting a location that has nothing yet is not an error")
    func deleteNothing() throws {
        let directory = try DerivedDataTestDirectory()
        try RuntimeDerivedDataMaintenance.deleteAll(at: directory.location())
        #expect(RuntimeDerivedDataMaintenance.allocatedByteCount(at: directory.location()) == 0)
    }
}
