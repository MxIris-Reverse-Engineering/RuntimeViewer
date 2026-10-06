import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerInjection
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
            let stagedURL = try fixture.makeStaging().stage(rendezvous: nil)

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
            try fixture.makeStaging().stage(rendezvous: nil)
            #expect(!(try fixture.stagedDependencyNames().contains("RuntimeViewerServer.framework")))
        }
    }

    @Test("Copies every embedded library, not just the one known to be needed")
    func copiesAllDependencies() throws {
        let addedLaterName = "libSomethingAddedLater.dylib"
        try withPayloadFixture(
            dependencyNames: [Self.looseDependencyName, Self.bundledDependencyName, addedLaterName],
        ) { fixture in
            try fixture.makeStaging().stage(rendezvous: nil)
            #expect(try fixture.stagedDependencyNames() == [Self.looseDependencyName, Self.bundledDependencyName, addedLaterName])
        }
    }

    @Test("Copies a dependency that is a bundle, not only a loose dylib")
    func copiesBundledDependenciesWholesale() throws {
        try withPayloadFixture { fixture in
            try fixture.makeStaging().stage(rendezvous: nil)
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
            let stagedURL = try fixture.makeStaging().stage(rendezvous: nil)
            #expect(try posixPermissions(ofItemAt: stagedURL) == 0o755)
        }
    }

    @Test("Leaves the staging directories traversable by everyone")
    func stagingDirectoriesAreWorldTraversable() throws {
        try withPayloadFixture { fixture in
            try fixture.makeStaging().stage(rendezvous: nil)
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
            try staging.stage(rendezvous: nil)
            let stagedURL = try staging.stage(rendezvous: nil)
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
            try staging.stage(rendezvous: nil)

            let unrelatedURL = fixture.stagingDirectoryURL.appendingPathComponent("someone-elses-file")
            try Data("keep me".utf8).write(to: unrelatedURL)
            try staging.stage(rendezvous: nil)

            #expect(try Data(contentsOf: unrelatedURL) == Data("keep me".utf8))
        }
    }

    /// A dependency dropped upstream must not survive in the staged copy, or the
    /// target loads a library the payload was not built against.
    @Test("Drops a dependency that is no longer embedded")
    func restagingRemovesVanishedDependencies() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage(rendezvous: nil)

            try FileManager.default.removeItem(
                at: fixture.dependencyDirectoryURL.appendingPathComponent(Self.looseDependencyName),
            )
            try staging.stage(rendezvous: nil)

            #expect(!(try fixture.stagedDependencyNames().contains(Self.looseDependencyName)))
        }
    }

    // MARK: - The rendezvous

    private static let rendezvous = RuntimePayloadRendezvous(
        hostAddress: "192.168.64.1",
        hostPort: 51234,
        claimToken: "06A9F1C2-1C1B-4A9E-9C2E-7E6A2F0D3B41",
    )

    /// It has to land where the payload looks, which is its own directory —
    /// asserted through the reader rather than by spelling the path again, so the
    /// two halves cannot drift apart while both tests keep passing.
    @Test("Writes the rendezvous where the payload reads it")
    func stagesTheRendezvousBesideThePayload() throws {
        try withPayloadFixture { fixture in
            let stagedURL = try fixture.makeStaging().stage(rendezvous: Self.rendezvous)
            let readBack = RuntimePayloadRendezvous.stagedInDirectory(
                at: stagedURL.deletingLastPathComponent(),
            )
            #expect(readBack == Self.rendezvous)
        }
    }

    /// The target reads it as whatever uid it runs as.
    @Test("Leaves the rendezvous readable by everyone")
    func stagedRendezvousIsWorldReadable() throws {
        try withPayloadFixture { fixture in
            let stagedURL = try fixture.makeStaging().stage(rendezvous: Self.rendezvous)
            let rendezvousURL = stagedURL
                .deletingLastPathComponent()
                .appendingPathComponent(RuntimePayloadRendezvous.fileName)
            #expect(try posixPermissions(ofItemAt: rendezvousURL) == 0o644)
        }
    }

    /// Overwritten, not appended to — it describes *this* injection. Appending
    /// would leave trailing bytes after the JSON object, and `JSONDecoder`
    /// rejects those, so the payload would read no rendezvous at all.
    @Test("Replaces the previous injection's rendezvous")
    func restagingReplacesTheRendezvous() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage(rendezvous: Self.rendezvous)

            let second = RuntimePayloadRendezvous(hostAddress: "10.0.0.9", hostPort: 59000, claimToken: "second")
            let stagedURL = try staging.stage(rendezvous: second)

            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: stagedURL.deletingLastPathComponent()) == second)
        }
    }

    /// The case with no symptom of its own. An injection that passes no
    /// rendezvous means "advertise yourself"; if the previous injection's file
    /// were left in place, this payload would instead dial a host that is no
    /// longer listening, and go quiet.
    @Test("Clears a leftover rendezvous when this injection passes none")
    func restagingWithoutARendezvousRemovesTheLeftoverOne() throws {
        try withPayloadFixture { fixture in
            let staging = fixture.makeStaging()
            try staging.stage(rendezvous: Self.rendezvous)
            let stagedURL = try staging.stage(rendezvous: nil)

            let directoryURL = stagedURL.deletingLastPathComponent()
            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: directoryURL) == nil)
            #expect(!FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent(RuntimePayloadRendezvous.fileName).path,
            ))
        }
    }

    /// Every way the read can come up empty answers `nil`, because the payload
    /// does the same thing in all of them. A malformed file throwing instead
    /// would have to be caught inside someone else's process, where there is
    /// nobody to report it to.
    @Test("Reads nothing rather than failing when the file is absent, corrupt or incomplete")
    func readingAnUnusableRendezvousAnswersNil() throws {
        try withPayloadFixture { fixture in
            let stagedURL = try fixture.makeStaging().stage(rendezvous: nil)
            let directoryURL = stagedURL.deletingLastPathComponent()
            let rendezvousURL = directoryURL.appendingPathComponent(RuntimePayloadRendezvous.fileName)

            // Absent.
            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: directoryURL) == nil)

            // Not JSON at all.
            try Data("half a file".utf8).write(to: rendezvousURL)
            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: directoryURL) == nil)

            // JSON, but missing a field the payload needs.
            try Data(#"{"hostAddress":"10.0.0.9"}"#.utf8).write(to: rendezvousURL)
            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: directoryURL) == nil)

            // Complete and well-formed, but naming nowhere to connect to.
            try JSONEncoder()
                .encode(RuntimePayloadRendezvous(hostAddress: "", hostPort: 0, claimToken: ""))
                .write(to: rendezvousURL)
            #expect(RuntimePayloadRendezvous.stagedInDirectory(at: directoryURL) == nil)
        }
    }

    /// What the payload does when the injector predates the rendezvous: there is
    /// no file beside it, and it has to answer "none" and go on to advertise
    /// itself. The call runs here exactly as it does in the payload — the handle
    /// is this image's, whichever image that is — and nothing is staged beside a
    /// test bundle, so this is that case.
    ///
    /// The directory-reading half is covered above, against a directory the test
    /// controls; this covers the step from a handle to a directory, which can
    /// only be exercised in whatever image the call is compiled into.
    @Test("Answers none, rather than trapping, when nothing is staged beside the image")
    func readsRelativeToTheCallingImage() {
        #expect(RuntimePayloadRendezvous.stagedBesideImage(#dsohandle) == nil)
    }

    // MARK: - Two injections at once

    /// **Two injections running at once must not share a staging directory.**
    ///
    /// `stage` removes and rewrites the payload, its dependencies and the
    /// rendezvous. An injection waits up to twenty seconds for the injector's
    /// verdict, so a second one starting inside that window rewrites the
    /// rendezvous the first payload has not read yet: it then dials the second
    /// injection's port and is claimed as the wrong target, or catches the gap
    /// between the remove and the write, finds no file, and falls back to
    /// advertising itself — which on a device whose target cannot bind is a
    /// payload that never reports at all.
    ///
    /// One picker serialises its own attaches, so this needs two requesters:
    /// a second document window, the MCP bridge, or the command-line tool,
    /// none of which can see each other's state.
    @Test("Two targets staged at once keep their own rendezvous")
    func concurrentInjectionsDoNotShareADirectory() throws {
        try withPayloadFixture { fixture in
            let shared = fixture.makeStaging()
            let firstRendezvous = RuntimePayloadRendezvous(
                hostAddress: "192.168.64.1",
                hostPort: 51234,
                claimToken: "FIRST-TOKEN",
            )
            let secondRendezvous = RuntimePayloadRendezvous(
                hostAddress: "192.168.64.1",
                hostPort: 51235,
                claimToken: "SECOND-TOKEN",
            )

            // Interleaved the way two requesters interleave: the first is still
            // waiting for its verdict when the second starts.
            let firstPayloadURL = try shared.isolated(forProcessWithIdentifier: 100).stage(rendezvous: firstRendezvous)
            let secondPayloadURL = try shared.isolated(forProcessWithIdentifier: 200).stage(rendezvous: secondRendezvous)

            #expect(firstPayloadURL != secondPayloadURL)
            // Each payload reads the rendezvous meant for it, through the same
            // reader the payload itself uses.
            #expect(
                RuntimePayloadRendezvous.stagedInDirectory(at: firstPayloadURL.deletingLastPathComponent())
                    == firstRendezvous
            )
            #expect(
                RuntimePayloadRendezvous.stagedInDirectory(at: secondPayloadURL.deletingLastPathComponent())
                    == secondRendezvous
            )
        }
    }

    /// Re-injecting one target reuses that target's directory rather than
    /// accumulating one per attempt — the behaviour the single shared directory
    /// already had, which is worth keeping for the common case.
    @Test("Staging the same target twice stays in one directory")
    func restagingOneTargetReusesItsDirectory() throws {
        try withPayloadFixture { fixture in
            let shared = fixture.makeStaging()
            let first = try shared.isolated(forProcessWithIdentifier: 100).stage(rendezvous: nil)
            let second = try shared.isolated(forProcessWithIdentifier: 100).stage(rendezvous: nil)
            #expect(first == second)
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
                try staging.stage(rendezvous: nil)
            }
        }
    }
}
