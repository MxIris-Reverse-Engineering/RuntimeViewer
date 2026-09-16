import Foundation
import MachO
import Testing

/// Pins the bridge's link model: it must carry **no** load command naming Xcode's private
/// frameworks.
///
/// This is not tidiness. A recorded dependency is matched by the string in the framework's own
/// `LC_ID_DYLIB`, and Xcode 27 changed that string — `@rpath/SourceEditor.framework/…` became
/// `@rpath/SharedFrameworks/SourceEditor.framework/…`. The loader `dlopen`s the frameworks by
/// absolute path before loading this bundle, so with a recorded dependency dyld looks for a name
/// no loaded image answers to, goes to the file system, finds nothing, and the bundle fails to
/// load. `SourceEditorLoader` then falls back to `NSTextView` — silently, because falling back is
/// its normal behaviour on any machine without Xcode.
///
/// Linking with `-undefined dynamic_lookup` (and Swift's autolink directives suppressed) removes
/// the dependency entirely: the symbols resolve in the flat namespace that `RTLD_GLOBAL` builds,
/// whatever the install names happen to be this year. Restoring `-framework` to the target's
/// `OTHER_LDFLAGS` is what this test fails on.
///
/// Nothing here needs Xcode installed, or even the frameworks present: it reads the built file.
///
/// See `Documentations/ResolvedIssues/2026-09-16-xcode27-shared-frameworks-install-name.md`.
@Suite("SourceEditorBridgeLinkage")
struct SourceEditorBridgeLinkageTests {
    /// The frameworks whose install names must not appear in any load command. `SourceModel` and
    /// `SourceModelSupport` were linked alongside `SourceEditor`; `_CodeCompletionFoundation` is
    /// only ever `dlopen`ed, and is listed so that linking it later trips this too.
    private static let xcodeFrameworkNames = [
        "SourceEditor",
        "SourceModel",
        "SourceModelSupport",
        "_CodeCompletionFoundation",
    ]

    @Test("the bridge records no dependency on Xcode's frameworks")
    func bridgeRecordsNoXcodeFrameworkDependency() throws {
        let dependencies = try MachOFileDependencies(fileURL: Self.bridgeBinaryURL())

        // Every architecture, not just this machine's: a Release build is universal, and the
        // x86_64 slice is linked by the same settings.
        #expect(!dependencies.byArchitecture.isEmpty, "no Mach-O slice was read from the bridge binary")

        for (architecture, dependencyNames) in dependencies.byArchitecture {
            let xcodeDependencies = dependencyNames.filter { name in
                Self.xcodeFrameworkNames.contains { name.contains("/\($0).framework/") }
            }
            #expect(
                xcodeDependencies.isEmpty,
                """
                The \(architecture) slice records \(xcodeDependencies.count) dependency on Xcode's \
                frameworks: \(xcodeDependencies.joined(separator: ", ")). The bridge has to link \
                with -undefined dynamic_lookup instead, or it stops loading whenever Xcode changes \
                an install name.
                """
            )
        }
    }

    /// Beside the test bundle, which is where the build puts it — the same place
    /// `SourceEditorTestHarness` loads it from.
    private static func bridgeBinaryURL() throws -> URL {
        let bundleURL = Bundle(for: BundleAnchor.self)
            .bundleURL
            .deletingLastPathComponent()
            .appending(path: "RuntimeViewerSourceEditorBridge.bundle")
        let binaryURL = bundleURL.appending(path: "Contents/MacOS/RuntimeViewerSourceEditorBridge")
        try #require(
            FileManager.default.fileExists(atPath: binaryURL.path),
            "no bridge binary at \(binaryURL.path)"
        )
        return binaryURL
    }

    private final class BundleAnchor {}
}

/// The dylib names recorded in each slice of a Mach-O file.
///
/// Read here rather than shelled out to `otool` so the test depends on nothing but the file, and
/// reports which slice is at fault when a universal build disagrees with itself.
private struct MachOFileDependencies {
    /// Keyed by `cputype`'s name, e.g. `"arm64"`.
    let byArchitecture: [String: [String]]

    init(fileURL: URL) throws {
        let fileContents = try Data(contentsOf: fileURL)
        var byArchitecture: [String: [String]] = [:]

        for sliceOffset in Self.sliceOffsets(in: fileContents) {
            guard let header = fileContents.loadUnaligned(at: sliceOffset, as: mach_header_64.self),
                  header.magic == MH_MAGIC_64
            else { continue }
            byArchitecture[Self.architectureName(of: header.cputype)] = Self.dylibNames(
                in: fileContents,
                sliceOffset: sliceOffset,
                header: header
            )
        }

        self.byArchitecture = byArchitecture
    }

    /// One entry for a thin file, one per `fat_arch` for a universal one. Fat headers are stored
    /// big-endian regardless of the host, which is what the byte swapping below is for.
    private static func sliceOffsets(in fileContents: Data) -> [Int] {
        guard let magic = fileContents.loadUnaligned(at: 0, as: UInt32.self) else { return [] }
        guard magic == FAT_CIGAM || magic == FAT_MAGIC else { return [0] }

        let isByteSwapped = magic == FAT_CIGAM
        guard let rawArchitectureCount = fileContents.loadUnaligned(at: 4, as: UInt32.self) else { return [] }
        let architectureCount = Int(isByteSwapped ? rawArchitectureCount.byteSwapped : rawArchitectureCount)

        return (0 ..< architectureCount).compactMap { architectureIndex in
            let entryOffset = MemoryLayout<fat_header>.size + architectureIndex * MemoryLayout<fat_arch>.size
            guard let entry = fileContents.loadUnaligned(at: entryOffset, as: fat_arch.self) else { return nil }
            return Int(isByteSwapped ? entry.offset.byteSwapped : entry.offset)
        }
    }

    /// `LC_LOAD_DYLIB` and its weak and re-exporting variants all record a dependency dyld has to
    /// resolve, so all three count.
    private static func dylibNames(in fileContents: Data, sliceOffset: Int, header: mach_header_64) -> [String] {
        var names: [String] = []
        var commandOffset = sliceOffset + MemoryLayout<mach_header_64>.size

        for _ in 0 ..< header.ncmds {
            guard let command = fileContents.loadUnaligned(at: commandOffset, as: load_command.self) else { break }
            let isDylibCommand = command.cmd == LC_LOAD_DYLIB
                || command.cmd == LC_LOAD_WEAK_DYLIB
                || command.cmd == LC_REEXPORT_DYLIB

            if isDylibCommand,
               let dylibCommand = fileContents.loadUnaligned(at: commandOffset, as: dylib_command.self) {
                let nameOffset = commandOffset + Int(dylibCommand.dylib.name.offset)
                let nameEnd = commandOffset + Int(command.cmdsize)
                if nameOffset < nameEnd, nameEnd <= fileContents.count {
                    let nameBytes = fileContents[nameOffset ..< nameEnd].prefix { $0 != 0 }
                    names.append(String(decoding: nameBytes, as: UTF8.self))
                }
            }

            commandOffset += Int(command.cmdsize)
        }

        return names
    }

    private static func architectureName(of cpuType: cpu_type_t) -> String {
        switch cpuType {
        case CPU_TYPE_ARM64: "arm64"
        case CPU_TYPE_X86_64: "x86_64"
        default: "cputype \(cpuType)"
        }
    }
}

extension Data {
    /// `nil` rather than a trap when the file is shorter than the structure being read, so a
    /// truncated or unexpected file fails the test's own assertion instead of the runner.
    fileprivate func loadUnaligned<Value>(at offset: Int, as type: Value.Type) -> Value? {
        guard offset >= 0, offset + MemoryLayout<Value>.size <= count else { return nil }
        return withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: type)
        }
    }
}
