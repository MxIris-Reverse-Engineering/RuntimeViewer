#if os(macOS)

import Foundation
import Testing
import Dependencies
import RuntimeViewerCore
@testable import RuntimeViewerEngineManagement
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerSettings

/// Opening a file from disk into an engine, the part the Mac's File › Open…
/// and the iOS apps' open button share (proposal `window-model-on-ios`). The
/// files are read in this process, as on iOS: the manager then refuses to
/// pair a listed file with another cache, which tells whether the opener
/// kept the listed pairing.
@Suite("RuntimeFileOpener", .serialized)
@MainActor
struct RuntimeFileOpenerTests {
    private struct Fixture {
        let manager: RuntimeEngineManager
        let opener: RuntimeFileOpener
    }

    private static func makeFixture() -> Fixture {
        let manager = RuntimeEngineManager(configuration: .application, startupHandler: { _ in })
        manager.fileReading = .inThisProcess
        let opener = withDependencies {
            $0.runtimeEngineManager = manager
            $0.settings = .preview
        } operation: {
            RuntimeFileOpener()
        }
        return Fixture(manager: manager, opener: opener)
    }

    @Test("a listed file is read again as the user paired it, not with the default cache")
    func listedFileKeepsItsPairing() async throws {
        let fixture = Self.makeFixture()
        let url = URL(fileURLWithPath: "/usr/bin/true")
        var file = try RuntimeFile(contentsOf: url)
        file.dependencyCache = nil
        let listedEngine = try await fixture.manager.runtimeEngine(reading: file)
        defer { fixture.manager.terminateRuntimeEngine(for: listedEngine.source) }

        let engine = try await fixture.opener.startReading(fileAt: url)

        #expect(engine === listedEngine)
        #expect(fixture.manager.file(of: engine)?.dependencyCache == nil)
    }

    @Test("a new file is paired with the default cache: this Mac's, for a macOS binary")
    func newFileIsPairedWithTheDefaultCache() async throws {
        let fixture = Self.makeFixture()

        let engine = try await fixture.opener.startReading(fileAt: URL(fileURLWithPath: "/usr/bin/false"))
        defer { fixture.manager.terminateRuntimeEngine(for: engine.source) }

        #expect(fixture.manager.file(of: engine)?.dependencyCache == .systemDyldSharedCache)
    }

    @Test("a file file mode does not read throws and lists nothing")
    func unreadableFileListsNothing() async throws {
        let fixture = Self.makeFixture()

        await #expect(throws: (any Error).self) {
            _ = try await fixture.opener.startReading(fileAt: URL(fileURLWithPath: "/etc/hosts"))
        }
        #expect(fixture.manager.fileRuntimeEngines.isEmpty)
    }

    @Test("letting go of a file read in this process takes its engine off the list")
    func lettingGoTakesTheEngineOffTheList() async throws {
        let fixture = Self.makeFixture()
        let engine = try await fixture.opener.startReading(fileAt: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(fixture.manager.fileRuntimeEngines.contains { $0 === engine })

        await fixture.opener.letGoOfFile(readBy: engine)

        #expect(!fixture.manager.fileRuntimeEngines.contains { $0 === engine })
    }
}

#endif
