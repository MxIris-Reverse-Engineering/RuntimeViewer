#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerHelperClient

/// Contract suite for `InjectionTargetPlatformProbe`.
///
/// History: injection delivered one payload — the macOS slice at
/// `/Library/Frameworks/RuntimeViewerServer.framework` — to every target. A
/// macOS process and an iOS Simulator process on the same Mac share a
/// `cputype`, so nothing about the target's architecture reveals the mismatch;
/// dyld only refuses at load time, and the injector's remap fallback then
/// killed the process outright. These tests pin the one signal that does tell
/// them apart: `LC_BUILD_VERSION`'s platform field.
@Suite("InjectionTargetPlatform")
struct InjectionTargetPlatformTests {
    // MARK: - Live processes

    @Test("This process reports macOS")
    func thisProcessIsMacOS() {
        #expect(InjectionTargetPlatformProbe.platform(ofProcess: getpid()) == .macOS)
    }

    @Test("A pid nobody owns yields no answer rather than a wrong one")
    func unknownProcessIsUnknown() {
        // pid 0 is the kernel's, which proc_pidpath cannot describe. The probe
        // must say "cannot tell" — a caller that reads a missing answer as
        // macOS would deliver the wrong slice to every unreadable target.
        #expect(InjectionTargetPlatformProbe.platform(ofProcess: 0) == nil)
    }

    // MARK: - Platform value mapping

    @Test("Load command platform values map to the slices we ship")
    func loadCommandValuesMap() {
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 1) == .macOS)
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 6) == .macCatalyst)
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 7) == .iOSSimulator)
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 8) == .tvOSSimulator)
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 9) == .watchOSSimulator)
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 11) == .visionOSSimulator)
    }

    @Test("An unknown platform is carried through rather than guessed at")
    func unknownPlatformIsCarried() {
        // PLATFORM_IOS (2) is a device build, which cannot run on a Mac. Naming
        // it in a refusal is more useful than silently picking a slice.
        #expect(InjectionTargetPlatformProbe.platform(forLoadCommandValue: 2) == .unsupported(2))
    }

    @Test("Only simulator platforms report isSimulator")
    func simulatorClassification() {
        #expect(InjectionTargetPlatform.iOSSimulator.isSimulator)
        #expect(InjectionTargetPlatform.tvOSSimulator.isSimulator)
        #expect(InjectionTargetPlatform.watchOSSimulator.isSimulator)
        #expect(InjectionTargetPlatform.visionOSSimulator.isSimulator)
        #expect(!InjectionTargetPlatform.macOS.isSimulator)
        // Catalyst runs on the host's dyld with the host's shared cache; it is
        // not a simulator however much its platform value looks adjacent.
        #expect(!InjectionTargetPlatform.macCatalyst.isSimulator)
        #expect(!InjectionTargetPlatform.unsupported(2).isSimulator)
    }

    // MARK: - Synthetic Mach-O files

    @Test("A thin file reports its own LC_BUILD_VERSION")
    func thinFileReportsBuildVersion() throws {
        let url = try MachOFixture.write(MachOFixture.thin(platform: 7))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .iOSSimulator)
    }

    @Test("A fat file reports the platform of its slices")
    func fatFileReportsSlicePlatform() throws {
        // The case this exists for: the shipped macOS payload is fat
        // (x86_64 + arm64 + arm64e) and must still read as macOS.
        let url = try MachOFixture.write(MachOFixture.fat(sliceCount: 3, platform: 1))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .macOS)
    }

    @Test("A byte-swapped header is read, not mistaken for garbage")
    func swappedHeaderIsRead() throws {
        let url = try MachOFixture.write(MachOFixture.thin(platform: 1, swapped: true))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .macOS)
    }

    @Test("A pre-LC_BUILD_VERSION binary falls back to its minimum-OS command")
    func minimumOSCommandIsFallback() throws {
        let url = try MachOFixture.write(MachOFixture.thin(minimumOSCommand: UInt32(LC_VERSION_MIN_MACOSX)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .macOS)
    }

    @Test("LC_BUILD_VERSION wins over a minimum-OS command in the same file")
    func buildVersionBeatsMinimumOSCommand() throws {
        // Binaries built for a wide deployment range carry both. Reading the
        // older one first would call an iOS Simulator payload macOS.
        let url = try MachOFixture.write(
            MachOFixture.thin(platform: 7, minimumOSCommand: UInt32(LC_VERSION_MIN_MACOSX))
        )
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .iOSSimulator)
    }

    // MARK: - Malformed input

    @Test("A truncated file yields no answer rather than a crash")
    func truncatedFileIsUnknown() throws {
        var bytes = MachOFixture.thin(platform: 7)
        bytes.removeLast(bytes.count / 2)
        let url = try MachOFixture.write(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        // The header still claims a load command the file no longer contains.
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == nil)
    }

    @Test("A load command claiming zero size does not spin forever")
    func zeroSizedLoadCommandTerminates() throws {
        let url = try MachOFixture.write(MachOFixture.thin(platform: 7, corruptCommandSize: 0))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == nil)
    }

    @Test("A file that is not Mach-O at all yields no answer")
    func nonMachOFileIsUnknown() throws {
        let url = try MachOFixture.write([UInt8]("not a mach-o file, just some text".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == nil)
    }

    @Test("A missing file yields no answer")
    func missingFileIsUnknown() {
        let url = URL(fileURLWithPath: "/nonexistent/RuntimeViewerProbe/binary")
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == nil)
    }

    // MARK: - A real simulator binary

    @Test("A real simulator runtime binary reports iOSSimulator")
    func realSimulatorBinaryIsDetected() throws {
        // Skipped rather than failed when no iOS runtime is installed: the
        // synthetic cases above already pin the parsing, and this one exists to
        // catch the day Apple changes what a simruntime binary looks like.
        guard let url = MachOFixture.installediOSSimulatorRuntimeBinaryURL() else { return }
        #expect(InjectionTargetPlatformProbe.platform(ofMachOFileAt: url) == .iOSSimulator)
    }
}

// MARK: - Fixtures

/// Builds the smallest Mach-O files that still exercise the probe: a header,
/// the load commands under test, and nothing else. Real binaries would make the
/// malformed cases impossible to express.
private enum MachOFixture {
    static func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectionTargetPlatformTests-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    /// A 64-bit Mach-O carrying up to two load commands.
    ///
    /// `corruptCommandSize` overrides the first command's `cmdsize`, which is
    /// how a malformed file makes a naive parser loop.
    static func thin(
        platform: UInt32? = nil,
        minimumOSCommand: UInt32? = nil,
        swapped: Bool = false,
        corruptCommandSize: UInt32? = nil
    ) -> [UInt8] {
        var commands: [UInt8] = []
        var commandCount: UInt32 = 0

        // Order matters: the minimum-OS command comes first so that a parser
        // returning on the first match it recognizes would answer with the
        // fallback instead of LC_BUILD_VERSION.
        if let minimumOSCommand {
            // version_min_command: cmd, cmdsize, version, sdk
            commands += word(minimumOSCommand, swapped: swapped)
            commands += word(16, swapped: swapped)
            commands += word(0x000A_0F00, swapped: swapped)
            commands += word(0x000A_0F00, swapped: swapped)
            commandCount += 1
        }

        if let platform {
            // build_version_command: cmd, cmdsize, platform, minos, sdk, ntools
            commands += word(UInt32(LC_BUILD_VERSION), swapped: swapped)
            commands += word(corruptCommandSize ?? 24, swapped: swapped)
            commands += word(platform, swapped: swapped)
            commands += word(0x000F_0000, swapped: swapped)
            commands += word(0x001A_0500, swapped: swapped)
            commands += word(0, swapped: swapped)
            commandCount += 1
        }

        // mach_header_64
        var bytes: [UInt8] = []
        // MH_CIGAM_64 already *is* MH_MAGIC_64's bytes read back on the other
        // endianness, so it goes in as-is; swapping it again would spell
        // MH_MAGIC_64 and the file would read as native after all.
        bytes += word(swapped ? MH_CIGAM_64 : MH_MAGIC_64, swapped: false)
        bytes += word(UInt32(bitPattern: CPU_TYPE_ARM64), swapped: swapped)
        bytes += word(0, swapped: swapped)                        // cpusubtype
        bytes += word(UInt32(MH_DYLIB), swapped: swapped)         // filetype
        bytes += word(commandCount, swapped: swapped)             // ncmds
        bytes += word(UInt32(commands.count), swapped: swapped)   // sizeofcmds
        bytes += word(0, swapped: swapped)                        // flags
        bytes += word(0, swapped: swapped)                        // reserved
        return bytes + commands
    }

    /// A fat file whose slices all carry the same platform, matching how a real
    /// multi-architecture build of one target looks.
    static func fat(sliceCount: Int, platform: UInt32) -> [UInt8] {
        let slice = thin(platform: platform)
        let headerSize = 8 + sliceCount * 20
        // Slices are page-aligned in real fat files; the probe does not require
        // it, but matching reality keeps the fixture honest.
        let alignment = 0x4000
        var sliceOffsets: [Int] = []
        var offset = (headerSize + alignment - 1) / alignment * alignment
        for _ in 0 ..< sliceCount {
            sliceOffsets.append(offset)
            offset += (slice.count + alignment - 1) / alignment * alignment
        }

        var bytes: [UInt8] = []
        bytes += bigEndianWord(FAT_MAGIC)
        bytes += bigEndianWord(UInt32(sliceCount))
        for (index, sliceOffset) in sliceOffsets.enumerated() {
            bytes += bigEndianWord(UInt32(bitPattern: index == 0 ? CPU_TYPE_X86_64 : CPU_TYPE_ARM64))
            bytes += bigEndianWord(UInt32(index))          // cpusubtype
            bytes += bigEndianWord(UInt32(sliceOffset))    // offset
            bytes += bigEndianWord(UInt32(slice.count))    // size
            bytes += bigEndianWord(14)                     // align (2^14 = 0x4000)
        }

        var file = bytes
        for sliceOffset in sliceOffsets {
            file += [UInt8](repeating: 0, count: sliceOffset - file.count)
            file += slice
        }
        return file
    }

    /// An arbitrary Mach-O from any installed iOS simulator runtime, or `nil`
    /// when none is installed.
    static func installediOSSimulatorRuntimeBinaryURL() -> URL? {
        let runtimeVolumes = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
        let fileManager = FileManager.default
        guard let volumes = try? fileManager.contentsOfDirectory(atPath: runtimeVolumes.path) else {
            return nil
        }
        for volume in volumes where volume.hasPrefix("iOS_") {
            let profiles = runtimeVolumes
                .appendingPathComponent(volume)
                .appendingPathComponent("Library/Developer/CoreSimulator/Profiles/Runtimes")
            guard let runtimes = try? fileManager.contentsOfDirectory(atPath: profiles.path) else { continue }
            for runtime in runtimes where runtime.hasSuffix(".simruntime") {
                let candidate = profiles
                    .appendingPathComponent(runtime)
                    .appendingPathComponent("Contents/Resources/RuntimeRoot/usr/lib/dyld_sim")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Byte helpers

    private static func word(_ value: UInt32, swapped: Bool) -> [UInt8] {
        withUnsafeBytes(of: swapped ? value.byteSwapped : value) { Array($0) }
    }

    private static func bigEndianWord(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}

#endif
