#if os(macOS)

import Foundation
import Testing

@testable import RuntimeViewerSettings

/// Pins how a build decides whether it can show interfaces in SourceEditor: the app has to carry
/// all four frameworks, and they have to be built for the architecture the app runs as. Anything
/// less is the built-in text view, and the Settings pane says which of the two this build uses.
@Suite("SourceEditorFrameworks")
struct SourceEditorFrameworksTests {
    @Test("a directory holding all four frameworks is complete, and one missing makes it incomplete")
    func completenessNeedsAllFour() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SourceEditorFrameworksTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in SourceEditorFrameworks.names {
            let binaryURL = SourceEditorFrameworks.binaryURL(of: name, in: directory)
            try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: binaryURL.path, contents: Data()))
        }
        #expect(SourceEditorFrameworks.containsAllFrameworks(in: directory))

        try FileManager.default.removeItem(at: directory.appending(path: "SourceModel.framework"))
        #expect(!SourceEditorFrameworks.containsAllFrameworks(in: directory))
    }

    @Test("a bundle that carries none of the frameworks is not embedded")
    func bundleWithoutFrameworksIsNotEmbedded() {
        // The test runner carries no SourceEditor frameworks.
        #expect(SourceEditorFrameworks.resolveAvailability(in: .main) == .notEmbedded)
    }

    @Test("an executable built for this process's architecture supports it")
    func ownExecutableSupportsRunningArchitecture() throws {
        // The test bundle was built for the architecture that is running it.
        let testBundle = Bundle(for: TestBundleMarker.self)
        #expect(SourceEditorFrameworks.supportsRunningArchitecture(testBundle))
    }

    @Test("a bundle with no executable supports no architecture")
    func bundleWithoutExecutableSupportsNothing() throws {
        let frameworkURL = FileManager.default.temporaryDirectory.appending(path: "SourceEditorFrameworksTests-\(UUID().uuidString).framework")
        defer { try? FileManager.default.removeItem(at: frameworkURL) }
        try FileManager.default.createDirectory(at: frameworkURL, withIntermediateDirectories: true)

        let bundle = try #require(Bundle(url: frameworkURL))
        #expect(!SourceEditorFrameworks.supportsRunningArchitecture(bundle))
    }
}

private final class TestBundleMarker {}

#endif
