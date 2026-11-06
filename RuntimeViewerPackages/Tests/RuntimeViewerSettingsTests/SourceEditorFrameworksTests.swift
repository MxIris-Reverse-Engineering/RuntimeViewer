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

    // MARK: - The Loaded Copy

    @Test("SourceEditor loaded from the app's own frameworks directory is the embedded reconstruction")
    func appCopyIsEmbedded() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworksDirectory = root.appending(path: "RuntimeViewer.app/Contents/Frameworks")
        let binaryPath = try Self.makeSourceEditorBinary(in: frameworksDirectory)

        #expect(SourceEditorFrameworks.loadedCopy(forBinaryAt: binaryPath, embeddedDirectory: frameworksDirectory) == .embedded)
    }

    /// The launch script's directory holds links into the Xcode, and dyld reports the path it
    /// opened — through the link.
    @Test("SourceEditor loaded through a link into an Xcode is that Xcode's copy, with its version")
    func linkedXcodeCopyIsXcode() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xcodeURL = root.appending(path: "Xcode-26.6.0.app")
        let sharedFrameworksDirectory = xcodeURL.appending(path: "Contents/SharedFrameworks")
        _ = try Self.makeSourceEditorBinary(in: sharedFrameworksDirectory)
        let infoDictionary: NSDictionary = ["CFBundleShortVersionString": "26.6"]
        try infoDictionary.write(to: xcodeURL.appending(path: "Contents/Info.plist"))
        let linkDirectory = root.appending(path: "Links")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkDirectory.appending(path: "SourceEditor.framework"),
            withDestinationURL: sharedFrameworksDirectory.appending(path: "SourceEditor.framework")
        )
        let binaryPath = linkDirectory.appending(path: "SourceEditor.framework/Versions/A/SourceEditor").path

        let copy = SourceEditorFrameworks.loadedCopy(forBinaryAt: binaryPath, embeddedDirectory: root.appending(path: "RuntimeViewer.app/Contents/Frameworks"))

        guard case .xcode(let bundleURL, let version) = copy else {
            Issue.record("expected Xcode's copy, got \(String(describing: copy))")
            return
        }
        #expect(bundleURL.path == xcodeURL.resolvingSymlinksInPath().path)
        #expect(version == "26.6")
    }

    @Test("SourceEditor loaded from anywhere else is named by its directory")
    func otherCopyIsNamedByItsDirectory() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherDirectory = root.appending(path: "Frameworks")
        let binaryPath = try Self.makeSourceEditorBinary(in: otherDirectory)

        let copy = SourceEditorFrameworks.loadedCopy(forBinaryAt: binaryPath, embeddedDirectory: root.appending(path: "RuntimeViewer.app/Contents/Frameworks"))

        #expect(copy == .other(directory: URL(fileURLWithPath: otherDirectory.resolvingSymlinksInPath().path, isDirectory: true)))
    }

    @Test("a binary that is not SourceEditor's names no copy")
    func otherBinaryNamesNoCopy() {
        #expect(SourceEditorFrameworks.loadedCopy(forBinaryAt: "/Applications/Xcode-26.6.0.app/Contents/SharedFrameworks/SourceModel.framework/Versions/A/SourceModel", embeddedDirectory: nil) == nil)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SourceEditorFrameworksTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An empty file where `SourceEditor`'s binary would be; returns its path.
    private static func makeSourceEditorBinary(in frameworksDirectory: URL) throws -> String {
        let binaryURL = SourceEditorFrameworks.binaryURL(of: "SourceEditor", in: frameworksDirectory)
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: binaryURL.path, contents: Data()))
        return binaryURL.path
    }
}

private final class TestBundleMarker {}

#endif
