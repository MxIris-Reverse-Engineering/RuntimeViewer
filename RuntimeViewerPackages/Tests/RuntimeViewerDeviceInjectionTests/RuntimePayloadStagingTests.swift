import Testing
import Foundation
@testable import RuntimeViewerDeviceInjection

/// The staged layout is the one part of device injection whose mistakes surface
/// inside *another* process, as a `dlopen` failure with no frame of ours in it.
/// So it is pinned here, against a real filesystem, on the platform that has a
/// test runner.
@Suite("Payload staging")
struct RuntimePayloadStagingTests {
    /// A throwaway stand-in for the hosting app's `Frameworks` directory: the
    /// payload inside its own `.framework` wrapper, plus what Xcode embeds
    /// beside it — one loose dylib and one framework bundle, so both shapes are
    /// copied by the tests below.
    private struct PayloadFixture {
        let rootURL: URL
        let dependencyDirectoryURL: URL
        let payloadURL: URL
        let stagingDirectoryURL: URL

        var stagedDependencyDirectoryURL: URL {
            stagingDirectoryURL.appendingPathComponent(RuntimePayloadStaging.dependencyDirectoryName, isDirectory: true)
        }

        func makeStaging() -> RuntimePayloadStaging {
            RuntimePayloadStaging(
                payloadURL: payloadURL,
                dependencyDirectoryURL: dependencyDirectoryURL,
                stagingDirectoryURL: stagingDirectoryURL,
            )
        }

        func stagedDependencyNames() throws -> Set<String> {
            try Set(FileManager.default.contentsOfDirectory(atPath: stagedDependencyDirectoryURL.path))
        }
    }

    private static let looseDependencyName = "libswiftCompatibilitySpan.dylib"
    private static let bundledDependencyName = "ObjCRuntimeToolbox.framework"

    private func withPayloadFixture(
        dependencyNames: [String] = [looseDependencyName, bundledDependencyName],
        _ body: (PayloadFixture) throws -> Void,
    ) throws {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RuntimePayloadStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let dependencyDirectoryURL = rootURL.appendingPathComponent("Frameworks", isDirectory: true)
        let payloadBundleURL = dependencyDirectoryURL
            .appendingPathComponent("RuntimeViewerServer.framework", isDirectory: true)
        try fileManager.createDirectory(at: payloadBundleURL, withIntermediateDirectories: true)

        let payloadURL = payloadBundleURL.appendingPathComponent("RuntimeViewerServer")
        try Data("payload".utf8).write(to: payloadURL)

        for dependencyName in dependencyNames {
            let dependencyURL = dependencyDirectoryURL.appendingPathComponent(dependencyName)
            if dependencyName.hasSuffix(".framework") {
                try fileManager.createDirectory(at: dependencyURL, withIntermediateDirectories: true)
                try Data(dependencyName.utf8).write(
                    to: dependencyURL.appendingPathComponent(dependencyName.replacingOccurrences(of: ".framework", with: "")),
                )
            } else {
                try Data(dependencyName.utf8).write(to: dependencyURL)
            }
        }

        try body(
            PayloadFixture(
                rootURL: rootURL,
                dependencyDirectoryURL: dependencyDirectoryURL,
                payloadURL: payloadURL,
                // Deliberately not created up front: creating it is part of
                // what `stage()` has to do.
                stagingDirectoryURL: rootURL.appendingPathComponent("Staging", isDirectory: true),
            ),
        )
    }

    private func posixPermissions(ofItemAt url: URL) throws -> UInt16? {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
    }

    // MARK: - The layout the loader needs

    /// The payload goes at the top of the staging directory and its
    /// dependencies one level down, because `@loader_path/Frameworks` — one of
    /// the payload's own run-path entries — is what resolves them.
    @Test("Puts the payload beside a Frameworks directory holding its dependencies")
    func producesTheLayoutTheRunPathExpects() throws {
        try withPayloadFixture { fixture in
            let stagedURL = try fixture.makeStaging().stage()

            #expect(stagedURL == fixture.stagingDirectoryURL.appendingPathComponent("RuntimeViewerServer"))
            #expect(FileManager.default.fileExists(atPath: stagedURL.path))

            // Spelled as the loader would resolve it, not as the fixture built
            // it: this is the assertion that fails if the layout drifts.
            let resolvedDependencyURL = stagedURL
                .deletingLastPathComponent()
                .appendingPathComponent("Frameworks")
                .appendingPathComponent(Self.looseDependencyName)
            #expect(FileManager.default.fileExists(atPath: resolvedDependencyURL.path))
        }
    }

    /// Named rather than `Frameworks` by coincidence: renaming it breaks loading
    /// in the target with nothing to point at the cause.
    @Test("Names the dependency directory after the payload's run-path entry")
    func dependencyDirectoryNameIsTheRunPathEntry() {
        #expect(RuntimePayloadStaging.dependencyDirectoryName == "Frameworks")
    }

    /// The payload is injected as a bare Mach-O, so its own `.framework`
    /// wrapper must not be copied again under `Frameworks` — that would be a
    /// second hundred megabytes for nothing.
    @Test("Leaves the payload's own bundle out of the dependencies")
    func doesNotCopyThePayloadBundleTwice() throws {
        try withPayloadFixture { fixture in
            try fixture.makeStaging().stage()
            #expect(!(try fixture.stagedDependencyNames().contains("RuntimeViewerServer.framework")))
        }
    }

    @Test("Copies every embedded library, not just the one known to be needed")
    func copiesAllDependencies() throws {
        let addedLaterName = "libSomethingAddedLater.dylib"
        try withPayloadFixture(
            dependencyNames: [Self.looseDependencyName, Self.bundledDependencyName, addedLaterName],
        ) { fixture in
            try fixture.makeStaging().stage()
            #expect(try fixture.stagedDependencyNames() == [Self.looseDependencyName, Self.bundledDependencyName, addedLaterName])
        }
    }

    @Test("Copies a dependency that is a bundle, not only a loose dylib")
    func copiesBundledDependenciesWholesale() throws {
        try withPayloadFixture { fixture in
            try fixture.makeStaging().stage()
            let innerBinaryURL = fixture.stagedDependencyDirectoryURL
                .appendingPathComponent(Self.bundledDependencyName)
                .appendingPathComponent("ObjCRuntimeToolbox")
            #expect(FileManager.default.fileExists(atPath: innerBinaryURL.path))
        }
    }

    // MARK: - Permissions

    /// The target is frequently a different uid, and it has to map the file.
    @Test("Leaves the staged payload readable and executable by everyone")
    func stagedPayloadIsWorldReadable() throws {
        try withPayloadFixture { fixture in
            let stagedURL = try fixture.makeStaging().stage()
            #expect(try posixPermissions(ofItemAt: stagedURL) == 0o755)
        }
    }

    @Test("Leaves the staging directories traversable by everyone")
    func stagingDirectoriesAreWorldTraversable() throws {
        try withPayloadFixture { fixture in
            try fixture.makeStaging().stage()
            #expect(try posixPermissions(ofItemAt: fixture.stagingDirectoryURL) == 0o755)
            #expect(try posixPermissions(ofItemAt: fixture.stagedDependencyDirectoryURL) == 0o755)
        }
    }

    // MARK: - Re-staging

    /// Injection stages every time, so the second run must not fail on what the
    /// first one left behind.
    @Test("Can stage twice over the same directory")
    func restagingReplacesThePreviousCopy() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage()
            let stagedURL = try staging.stage()
            #expect(try Data(contentsOf: stagedURL) == Data("payload".utf8))
        }
    }

    /// Re-staging rewrites the payload and the dependency directory, and nothing
    /// else: the staging directory may be a shared location such as
    /// `/private/var/tmp`.
    @Test("Keeps unrelated files in the staging directory")
    func restagingLeavesUnrelatedFilesAlone() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage()

            let unrelatedURL = fixture.stagingDirectoryURL.appendingPathComponent("someone-elses-file")
            try Data("keep me".utf8).write(to: unrelatedURL)
            try staging.stage()

            #expect(try Data(contentsOf: unrelatedURL) == Data("keep me".utf8))
        }
    }

    /// A dependency dropped upstream must not survive in the staged copy, or the
    /// target loads a library the payload was not built against.
    @Test("Drops a dependency that is no longer embedded")
    func restagingRemovesVanishedDependencies() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage()

            try FileManager.default.removeItem(
                at: fixture.dependencyDirectoryURL.appendingPathComponent(Self.looseDependencyName),
            )
            try staging.stage()

            #expect(!(try fixture.stagedDependencyNames().contains(Self.looseDependencyName)))
        }
    }

    // MARK: - Failure

    @Test("Reports a missing payload rather than staging an empty directory")
    func missingPayloadThrows() throws {
        try withPayloadFixture { fixture in
            let staging = RuntimePayloadStaging(
                payloadURL: fixture.rootURL.appendingPathComponent("absent/RuntimeViewerServer"),
                dependencyDirectoryURL: fixture.dependencyDirectoryURL,
                stagingDirectoryURL: fixture.stagingDirectoryURL,
            )
            #expect(throws: (any Error).self) {
                try staging.stage()
            }
        }
    }
}
