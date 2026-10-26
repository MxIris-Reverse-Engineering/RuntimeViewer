import Foundation
import Testing
@testable import RuntimeViewerCore

/// The store: where things go, what reads them back, and the reading marker
/// that keeps a file which takes the process down from being read twice.
@Suite("RuntimeDerivedDataStore")
struct RuntimeDerivedDataStoreTests {
    private static let imagePath = "/usr/lib/libobjc.A.dylib"
    private static let kind = RuntimeDerivedDataKind(rawValue: "TestKind")
    private static let section = RuntimeDerivedDataContainer.SectionIdentifier(rawValue: 1)

    private static func builder(_ text: String) -> RuntimeDerivedDataContainer.Builder {
        var builder = RuntimeDerivedDataContainer.Builder()
        builder.append(Data(text.utf8), as: section)
        return builder
    }

    private static func text(of container: RuntimeDerivedDataContainer) throws -> String {
        String(decoding: try container.section(section), as: UTF8.self)
    }

    private static func containerURL(in store: RuntimeDerivedDataStore, variant: String = "A") throws -> URL {
        try #require(store.containerURL(kind, variant: variant, forImageAt: imagePath))
    }

    @Test("What is stored is read back, and nothing is left beside it")
    func roundTrip() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)

        let text = await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:))
        #expect(text == "hello")
        let containerURL = try Self.containerURL(in: store)
        let leftNames = try FileManager.default.contentsOfDirectory(atPath: containerURL.deletingLastPathComponent().path)
        #expect(leftNames == [containerURL.lastPathComponent], "no marker, no temporary file")
    }

    @Test("The layout is system, producer, Images, image, file")
    func layout() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)

        let systemURL = directory.location().rootURL.appendingPathComponent(DerivedDataTestIdentities.system.directoryName)
        let producerURL = systemURL.appendingPathComponent(DerivedDataTestIdentities.producer.directoryName)
        let fileManager = FileManager.default
        #expect(fileManager.fileExists(atPath: systemURL.appendingPathComponent("Info.plist").path))
        #expect(fileManager.fileExists(atPath: producerURL.appendingPathComponent("Info.plist").path))
        #expect(fileManager.fileExists(atPath: producerURL.appendingPathComponent("LastUsed").path))
        let imageDirectoryNames = try fileManager.contentsOfDirectory(atPath: producerURL.appendingPathComponent("Images").path)
        #expect(imageDirectoryNames.count == 1)
        #expect(imageDirectoryNames.first?.hasPrefix("libobjc.A.dylib-") == true)
        #expect(try Self.containerURL(in: store).lastPathComponent == "TestKind-A.rvdd")
    }

    @Test("Two images of one file name get directories of their own")
    func sameFileNameDifferentPaths() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        let macOSPath = "/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore"
        let catalystPath = "/System/iOSSupport/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore"
        #expect(store.imageDirectory(forImageAt: macOSPath) != store.imageDirectory(forImageAt: catalystPath))
        await store.store(Self.builder("macOS"), as: Self.kind, variant: "A", forImageAt: macOSPath)
        await store.store(Self.builder("Catalyst"), as: Self.kind, variant: "A", forImageAt: catalystPath)
        #expect(await store.read(Self.kind, variant: "A", forImageAt: macOSPath, decode: Self.text(of:)) == "macOS")
        #expect(await store.read(Self.kind, variant: "A", forImageAt: catalystPath, decode: Self.text(of:)) == "Catalyst")
    }

    @Test("Another producer or another system finds nothing")
    func otherIdentities() async throws {
        let directory = try DerivedDataTestDirectory()
        await DerivedDataTestIdentities.store(in: directory).store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)

        let otherProducer = DerivedDataTestIdentities.store(in: directory, producer: DerivedDataTestIdentities.otherProducer)
        #expect(await otherProducer.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
        let otherSystem = DerivedDataTestIdentities.store(in: directory, system: RuntimeDerivedDataSystemIdentity(
            platform: .macOS, operatingSystemVersion: "27.3", operatingSystemBuild: "26C5000a", sharedCacheUUID: UUID()
        ))
        #expect(await otherSystem.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
        let catalyst = DerivedDataTestIdentities.store(in: directory, system: RuntimeDerivedDataSystemIdentity(
            platform: .macCatalyst, operatingSystemVersion: "27.2", operatingSystemBuild: "26B5112a", sharedCacheUUID: DerivedDataTestIdentities.sharedCacheUUID
        ))
        #expect(await catalyst.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
    }

    @Test("A file moved into another image's place reads as nothing stored, and is deleted")
    func misplacedFile() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let otherImagePath = "/usr/lib/libSystem.B.dylib"
        let otherURL = try #require(store.containerURL(Self.kind, variant: "A", forImageAt: otherImagePath))
        try FileManager.default.createDirectory(at: otherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try Self.containerURL(in: store), to: otherURL)

        #expect(await store.read(Self.kind, variant: "A", forImageAt: otherImagePath, decode: Self.text(of:)) == nil)
        #expect(!FileManager.default.fileExists(atPath: otherURL.path))
    }

    @Test("An image outside the shared cache is neither written nor read")
    func imagesOutsideTheSharedCache() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory, isSharedCacheImage: { $0.hasPrefix("/System/") })
        let applicationImagePath = "/Applications/Example.app/Contents/MacOS/Example"
        #expect(store.imageDirectory(forImageAt: applicationImagePath) == nil)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: applicationImagePath)
        #expect(await store.read(Self.kind, variant: "A", forImageAt: applicationImagePath, decode: Self.text(of:)) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.location().rootURL.path))
    }

    @Test("Writing a variant deletes the image's other variants of that kind, and only those")
    func writingReplacesOtherVariants() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        let otherKind = RuntimeDerivedDataKind(rawValue: "OtherKind")
        await store.store(Self.builder("first"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        await store.store(Self.builder("other kind"), as: otherKind, variant: "A", forImageAt: Self.imagePath)
        await store.store(Self.builder("second"), as: Self.kind, variant: "B", forImageAt: Self.imagePath)

        #expect(await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
        #expect(await store.read(Self.kind, variant: "B", forImageAt: Self.imagePath, decode: Self.text(of:)) == "second")
        #expect(await store.read(otherKind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == "other kind")
    }

    #if os(macOS)
    /// A file is `<kind>-<variant>.rvdd`, and a variant has hyphens of its own:
    /// a kind named `InterfaceCorpus-Members` would have its files taken for
    /// variants of `InterfaceCorpus`, and deleted whenever one of those is
    /// written (PR126.7).
    @Test("A kind is named with ASCII letters and digits alone")
    func kindNames() async {
        #expect(RuntimeDerivedDataKind.interfaceCorpus.rawValue == "InterfaceCorpus")
        await #expect(processExitsWith: .failure) {
            _ = RuntimeDerivedDataKind(rawValue: "InterfaceCorpus-Members")
        }
        await #expect(processExitsWith: .failure) {
            _ = RuntimeDerivedDataKind(rawValue: "")
        }
    }
    #endif

    @Test("A file that fails its checks is deleted")
    func damagedFile() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder(String(repeating: "hello ", count: 100)), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let containerURL = try Self.containerURL(in: store)
        var bytes = try Data(contentsOf: containerURL)
        bytes[bytes.count - 3] ^= 0xFF
        try bytes.write(to: containerURL)

        #expect(await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
        #expect(!FileManager.default.fileExists(atPath: containerURL.path))
    }

    @Test("A file its decoder rejects is deleted")
    func decoderRejection() async throws {
        struct Rejected: Error {}
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let value: String? = await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath) { _ in throw Rejected() }
        #expect(value == nil)
        #expect(!FileManager.default.fileExists(atPath: try Self.containerURL(in: store).path))
    }

    @Test("A marker of a read that never finished deletes the file unread")
    func deadReader() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory, isProcessRunning: { _ in false })
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let containerURL = try Self.containerURL(in: store)
        let markerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: containerURL)
        try RuntimeDerivedDataReadingMarker(processIdentifier: 99999, processStartTime: 1).write(to: markerURL)

        let decodeCalls = DerivedDataCallCounter()
        let value = await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath) { container in
            decodeCalls.increment()
            return try Self.text(of: container)
        }
        #expect(value == nil)
        #expect(decodeCalls.value == 0)
        #expect(!FileManager.default.fileExists(atPath: containerURL.path))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("A file another running process is reading is left alone")
    func liveReader() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory, isProcessRunning: { _ in true })
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let containerURL = try Self.containerURL(in: store)
        let markerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: containerURL)
        try RuntimeDerivedDataReadingMarker(processIdentifier: 99999, processStartTime: 1).write(to: markerURL)

        #expect(await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath, decode: Self.text(of:)) == nil)
        #expect(FileManager.default.fileExists(atPath: containerURL.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("The marker stays until the decoder is done with what it read")
    func markerSpansTheDecoder() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let markerURL = RuntimeDerivedDataReadingMarker.url(forContainerAt: try Self.containerURL(in: store))

        let markerWasPresent = DerivedDataCallCounter()
        let value = await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath) { container in
            if let marker = RuntimeDerivedDataReadingMarker(contentsOf: markerURL), marker == .currentProcess() {
                markerWasPresent.increment()
            }
            return try Self.text(of: container)
        }
        #expect(value == "hello")
        #expect(markerWasPresent.value == 1)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("A real process's marker is told from one whose process is gone")
    func markerLiveness() {
        #expect(RuntimeDerivedDataReadingMarker.isProcessRunning(.currentProcess()))
        let current = RuntimeDerivedDataReadingMarker.currentProcess()
        #expect(!RuntimeDerivedDataReadingMarker.isProcessRunning(.init(processIdentifier: current.processIdentifier, processStartTime: current.processStartTime &+ 1)), "same identifier, later start: another process")
        #expect(!RuntimeDerivedDataReadingMarker.isProcessRunning(.init(processIdentifier: 0, processStartTime: 0)))
    }

    /// The decode is held until every reader has joined the read, however
    /// late its task is scheduled: one reader comes 0.3 seconds late, as one
    /// does under a loaded machine, which the test used to take for a second
    /// read (PR126.13).
    @Test("Reads of one file at the same time decode it once")
    func concurrentReadsJoin() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let readerCount = 8

        let decodeCalls = DerivedDataCallCounter()
        let decodeMayFinish = DispatchSemaphore(value: 0)
        let values = await withTaskGroup(of: String?.self) { group in
            for readerIndex in 0 ..< readerCount {
                group.addTask {
                    if readerIndex == readerCount - 1 {
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    return await store.read(Self.kind, variant: "A", forImageAt: Self.imagePath) { container in
                        decodeCalls.increment()
                        decodeMayFinish.wait()
                        return try Self.text(of: container)
                    }
                }
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while await store.readerCount(of: Self.kind, variant: "A", forImageAt: Self.imagePath) < readerCount, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            decodeMayFinish.signal()
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(values == Array(repeating: "hello", count: readerCount))
        #expect(decodeCalls.value == 1)
    }

    @Test("Every write refreshes LastUsed")
    func writesRefreshLastUsed() async throws {
        let directory = try DerivedDataTestDirectory()
        let store = DerivedDataTestIdentities.store(in: directory)
        await store.store(Self.builder("hello"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let lastUsedURL = store.producerDirectoryURL.appendingPathComponent("LastUsed")
        let longAgo = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        try FileManager.default.setModificationDate(longAgo, of: lastUsedURL)

        await store.store(Self.builder("again"), as: Self.kind, variant: "A", forImageAt: Self.imagePath)
        let modificationDate = try #require(FileManager.default.attributesOfItem(atPath: lastUsedURL.path)[.modificationDate] as? Date)
        #expect(modificationDate.timeIntervalSinceNow > -60)
    }
}
