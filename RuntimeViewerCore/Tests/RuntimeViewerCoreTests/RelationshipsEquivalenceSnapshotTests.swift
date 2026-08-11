import Testing
import Foundation
import RuntimeViewerCore

/// Golden-file equivalence guard for Evolution 0007, which moves the Objective-C
/// relationship reverse tables out of `ObjCIndexing` and rebuilds them here from
/// the library's event stream.
///
/// The snapshot is taken through `RuntimeEngine.relationships(for:)` — the public
/// API whose output is what users actually see, and the only vantage point that
/// exists both before and after the migration. (The internal
/// `ObjCInterfaceIndexer.subclasses(of:)` disappears with the library change, so
/// it cannot serve as a shared baseline.)
///
/// Capture the baseline **before** bumping the MachOObjCSection pin: once the
/// old implementation is gone there is nothing left to compare against. Missing
/// snapshot files are written on the spot and reported as a failure, so a
/// forgotten baseline is loud rather than silent.
@Suite("Relationships equivalence snapshot", .serialized)
struct RelationshipsEquivalenceSnapshotTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    /// Anchors chosen for what each one proves about equivalence:
    ///
    /// - `NSObject` — the largest subclass set available, spanning two images,
    ///   so a dropped image or a broken cross-image union shows up immediately.
    /// - `NSCoding` / `NSCopying` — Objective-C protocols adopted both inline and
    ///   through categories. The library wrote both kinds into one table; if the
    ///   rebuilt index splits them apart and queries only one, these shrink.
    private static let subclassAnchors = ["NSObject"]
    private static let protocolAnchors = ["NSCoding", "NSCopying"]

    @Test("Relationships output matches the pre-migration baseline")
    func matchesBaseline() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-rel-equivalence-snapshot")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)

        var report = ""

        for className in Self.subclassAnchors {
            let anchor = try #require(
                await findObject(named: className, kind: .objc(.type(.class)), in: engine),
                "Anchor class \(className) not found in the loaded images."
            )
            let relationships = try await engine.relationships(for: anchor)
            report += render(section: "subclasses of \(className)", objects: relationships.subclasses)
        }

        for protocolName in Self.protocolAnchors {
            let anchor = try #require(
                await findObject(named: protocolName, kind: .objc(.type(.protocol)), in: engine),
                "Anchor protocol \(protocolName) not found in the loaded images."
            )
            let relationships = try await engine.relationships(for: anchor)
            report += render(section: "conformers of \(protocolName)", objects: relationships.conformingTypes)
        }

        try compare(report, againstSnapshotNamed: "relationships-baseline.txt")
    }

    // MARK: - Rendering

    /// One line per entry: `kind|displayName|imagePath`.
    ///
    /// `imagePath` is included deliberately — a category-contributed conformer
    /// carries the image declaring the *category*, not the one declaring the
    /// class, and that asymmetry is existing behaviour the migration must
    /// preserve verbatim.
    private func render(section: String, objects: [RuntimeObject]) -> String {
        var rendered = "## \(section) (\(objects.count))\n"
        for object in objects {
            rendered += "\(object.kind)|\(object.displayName)|\(object.imagePath)\n"
        }
        return rendered + "\n"
    }

    private func findObject(
        named name: String,
        kind: RuntimeObjectKind,
        in engine: RuntimeEngine
    ) async -> RuntimeObject? {
        for imagePath in await engine.loadedImagePaths {
            guard let objects = try? await engine.objects(in: imagePath) else { continue }
            if let match = objects.first(where: { $0.name == name && $0.kind == kind }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Snapshot IO

    /// Snapshots live next to this source file so they are reviewable in diffs
    /// and travel with the branch; `#filePath` avoids depending on test-bundle
    /// resource plumbing.
    private func snapshotDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots", isDirectory: true)
    }

    private func compare(_ report: String, againstSnapshotNamed fileName: String) throws {
        let snapshotURL = snapshotDirectory().appendingPathComponent(fileName)

        guard let recorded = try? String(contentsOf: snapshotURL, encoding: .utf8) else {
            try FileManager.default.createDirectory(
                at: snapshotDirectory(),
                withIntermediateDirectories: true
            )
            try report.write(to: snapshotURL, atomically: true, encoding: .utf8)
            Issue.record(
                """
                No baseline snapshot existed; one was just written to \(snapshotURL.path).
                Review it, commit it, and re-run. This failure is expected exactly once — \
                on the run that captures the baseline.
                """
            )
            return
        }

        guard recorded != report else { return }

        let recordedLines = recorded.components(separatedBy: "\n")
        let reportLines = report.components(separatedBy: "\n")
        let missing = Set(recordedLines).subtracting(reportLines).sorted()
        let unexpected = Set(reportLines).subtracting(recordedLines).sorted()

        Issue.record(
            """
            Relationships output diverged from the baseline.
            Missing \(missing.count) line(s): \(missing.prefix(20).joined(separator: ", "))
            Unexpected \(unexpected.count) line(s): \(unexpected.prefix(20).joined(separator: ", "))
            """
        )
    }
}
