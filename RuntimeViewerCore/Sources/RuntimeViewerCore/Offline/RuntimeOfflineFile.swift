public import Foundation
public import RuntimeViewerCommunication
import MachOKit
import MachODependencies

/// A file offline mode reads — a Mach-O file, a bundle or a dyld shared cache
/// on disk — and where the images it links come from when they are not inside
/// it.
///
/// What an offline engine is made of. It travels from the app to the process
/// that reads the file as that process's launch payload, so it is `Codable`.
/// The engine's identity is the URL alone (`RuntimeSource.file`); everything
/// else here is configuration, so pairing a file with another dyld shared
/// cache keeps its bookmarks and settings.
public struct RuntimeOfflineFile: Sendable, Hashable, Codable {
    /// What kind of file `url` names.
    public enum Content: Sendable, Hashable, Codable {
        /// A thin Mach-O file, or one slice of a fat one.
        case machO(slice: Slice?)
        /// A bundle: its main executable and every Mach-O file inside it.
        case bundle
        /// The main file of a dyld shared cache; its subcaches lie next to it.
        case dyldSharedCache
    }

    /// One slice of a fat file, by its CPU type and subtype.
    public struct Slice: Sendable, Hashable, Codable {
        public let cpuType: Int32
        public let cpuSubtype: Int32

        public init(cpuType: Int32, cpuSubtype: Int32) {
            self.cpuType = cpuType
            self.cpuSubtype = cpuSubtype
        }
    }

    /// Where the images a Mach-O file or a bundle links come from, when they
    /// are not inside it.
    public enum DependencyCache: Sendable, Hashable, Codable {
        /// This Mac's dyld shared cache.
        case systemDyldSharedCache
        /// A dyld shared cache read from disk, by the URL of its main file.
        case dyldSharedCache(URL)
    }

    /// The platform a file was built for and a version: the SDK's for a Mach-O
    /// file or a bundle, the operating system's for a dyld shared cache.
    public struct Platform: Sendable, Hashable, Codable {
        /// `macOS`, `macCatalyst`, `iOS`, `iOSSimulator`, `tvOS`, `watchOS`,
        /// `visionOS`, their simulators, `driverKit` — or the load command's
        /// own description for a platform outside that list.
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    /// The file, standardized, with symbolic links resolved.
    public let url: URL

    public let content: Content

    /// `nil` reads the file alone. Ignored for a dyld shared cache, which is
    /// its own.
    public var dependencyCache: DependencyCache?

    /// What the file says it was built for, or `nil` when it says nothing.
    public let platform: Platform?

    /// What menus show: the bundle's or the file's name, or the platform,
    /// version and architecture of a dyld shared cache.
    public let displayName: String

    public init(url: URL, content: Content, dependencyCache: DependencyCache? = nil, platform: Platform?, displayName: String) {
        self.url = url
        self.content = content
        self.dependencyCache = dependencyCache
        self.platform = platform
        self.displayName = displayName
    }

    /// Inspects what is at `url`: a bundle, a dyld shared cache — a subcache
    /// stands for its main file — or a Mach-O file, picking the slice of a fat
    /// one this Mac prefers. Reads headers and load commands only, never an
    /// image's metadata. `dependencyCache` starts out `nil`.
    ///
    /// Throws `RuntimeOfflineFileError`.
    public init(contentsOf url: URL) throws {
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw RuntimeOfflineFileError.unreadable(fileURL)
        }
        if isDirectory.boolValue {
            guard let executableURL = Bundle(url: fileURL)?.executableURL else {
                throw RuntimeOfflineFileError.bundleWithoutExecutable(fileURL)
            }
            let executable = try Self.machOFile(at: executableURL, preferring: nil)
            self.init(url: fileURL, content: .bundle, platform: Self.platform(of: executable), displayName: fileURL.lastPathComponent)
            return
        }
        let leadingBytes = try Self.leadingBytes(of: fileURL)
        if leadingBytes.starts(with: Array("dyld_v1".utf8)) {
            let mainCacheURL = Self.mainCacheURL(for: fileURL)
            let cache = try DyldCache(url: mainCacheURL)
            let platform = Self.platform(ofCacheHeader: cache.header)
            let architecture = cache.header.magic
                .replacingOccurrences(of: "dyld_v1", with: "")
                .trimmingCharacters(in: .whitespaces)
            let platformDescription = platform.map { "\($0.name) \($0.version)" } ?? "Unknown Platform"
            self.init(
                url: mainCacheURL,
                content: .dyldSharedCache,
                platform: platform,
                displayName: "\(platformDescription) dyld cache (\(architecture))"
            )
            return
        }
        guard Self.isMachOOrFatMagic(leadingBytes) else {
            throw RuntimeOfflineFileError.unsupportedContent(fileURL)
        }
        let machOFile = try Self.machOFile(at: fileURL, preferring: nil)
        let slice: Slice? = Self.isFatMagic(leadingBytes) ? Slice(cpuType: machOFile.header.layout.cputype, cpuSubtype: machOFile.header.layout.cpusubtype) : nil
        self.init(url: fileURL, content: .machO(slice: slice), platform: Self.platform(of: machOFile), displayName: fileURL.lastPathComponent)
    }

    public var source: RuntimeSource {
        .file(name: displayName, url: url)
    }
}

// MARK: - Reading Headers

extension RuntimeOfflineFile {
    /// The Mach-O file at `url`: the file itself, or the slice of a fat one
    /// `slice` names — the one this Mac prefers when `slice` is `nil`.
    static func machOFile(at url: URL, preferring slice: Slice?) throws -> MachOFile {
        let file: File
        do {
            file = try File.loadFromFile(url: url)
        } catch {
            throw RuntimeOfflineFileError.unsupportedContent(url)
        }
        switch file {
        case .machO(let machOFile):
            return machOFile
        case .fat(let fatFile):
            guard let machOFiles = try? fatFile.machOFiles(), !machOFiles.isEmpty else {
                throw RuntimeOfflineFileError.noSupportedSlice(url)
            }
            if let slice {
                guard let matching = machOFiles.first(where: { Self.cpuSubtypeMatches($0, slice) }) else {
                    throw RuntimeOfflineFileError.noSupportedSlice(url)
                }
                return matching
            }
            guard let preferred = machOFiles.min(by: { Self.slicePreference(of: $0) < Self.slicePreference(of: $1) }),
                  Self.slicePreference(of: preferred) < Int.max
            else {
                throw RuntimeOfflineFileError.noSupportedSlice(url)
            }
            return preferred
        }
    }

    /// The order slices are picked in: arm64e, arm64, x86_64; everything
    /// else is never picked by itself.
    private static func slicePreference(of machOFile: MachOFile) -> Int {
        let cpuType = machOFile.header.layout.cputype
        let cpuSubtype = machOFile.header.layout.cpusubtype & ~Int32(bitPattern: 0xFF00_0000)
        switch (cpuType, cpuSubtype) {
        case (Self.cpuTypeARM64, Self.cpuSubtypeARM64E): return 0
        case (Self.cpuTypeARM64, _): return 1
        case (Self.cpuTypeX86_64, _): return 2
        default: return .max
        }
    }

    /// `CPU_TYPE_ARM64`, `CPU_SUBTYPE_ARM64E` and `CPU_TYPE_X86_64` from
    /// `<mach/machine.h>`, whose macros do not import into Swift.
    private static var cpuTypeARM64: Int32 { 0x0100_000C }
    private static var cpuSubtypeARM64E: Int32 { 2 }
    private static var cpuTypeX86_64: Int32 { 0x0100_0007 }

    private static func cpuSubtypeMatches(_ machOFile: MachOFile, _ slice: Slice) -> Bool {
        let capabilityMask = ~Int32(bitPattern: 0xFF00_0000)
        return machOFile.header.layout.cputype == slice.cpuType
            && machOFile.header.layout.cpusubtype & capabilityMask == slice.cpuSubtype & capabilityMask
    }

    static func platform(of machO: some MachORepresentable) -> Platform? {
        let platforms = DependencyPlatforms.platforms(of: machO)
        // A zippered image declares macOS and Mac Catalyst; it is a macOS one.
        let chosen: MachOKit.Platform? = platforms.contains(.macOS) ? .macOS : platforms.sorted { $0.rawValue < $1.rawValue }.first
        guard let chosen else { return nil }
        let loadCommands = machO.loadCommands
        let sdk: MachOKit.Version? = loadCommands.infos(of: LoadCommand.buildVersion).first { $0.platform == chosen }?.sdk
            ?? loadCommands.info(of: LoadCommand.versionMinMacosx)?.sdk
            ?? loadCommands.info(of: LoadCommand.versionMinIphoneos)?.sdk
            ?? loadCommands.info(of: LoadCommand.versionMinTvos)?.sdk
            ?? loadCommands.info(of: LoadCommand.versionMinWatchos)?.sdk
        return Platform(name: Self.name(of: chosen), version: sdk.map(Self.versionString) ?? "")
    }

    static func platform(ofCacheHeader header: DyldCacheHeader) -> Platform? {
        guard header.platform != .unknown else { return nil }
        return Platform(name: Self.name(of: header.platform), version: Self.versionString(header.osVersion))
    }

    static func name(of platform: MachOKit.Platform) -> String {
        switch platform {
        case .macOS: "macOS"
        case .macCatalyst: "macCatalyst"
        case .iOS: "iOS"
        case .iOSSimulator: "iOSSimulator"
        case .tvOS: "tvOS"
        case .tvOSSimulator: "tvOSSimulator"
        case .watchOS: "watchOS"
        case .watchOSSimulator: "watchOSSimulator"
        case .visionOS: "visionOS"
        case .visionOSSimulator: "visionOSSimulator"
        case .driverKit: "driverKit"
        default: platform.description
        }
    }

    static func versionString(_ version: MachOKit.Version) -> String {
        version.patch == 0 ? "\(version.major).\(version.minor)" : "\(version.major).\(version.minor).\(version.patch)"
    }

    private static func leadingBytes(of url: URL) throws -> [UInt8] {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw RuntimeOfflineFileError.unreadable(url)
        }
        defer { try? fileHandle.close() }
        return Array((try? fileHandle.read(upToCount: 16)) ?? Data())
    }

    private static func isMachOOrFatMagic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let magics: Set<[UInt8]> = [
            [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], // MH_MAGIC_64, MH_MAGIC (little-endian)
            [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE], // big-endian
        ]
        return magics.contains(Array(bytes.prefix(4))) || isFatMagic(bytes)
    }

    /// `FAT_MAGIC` or `FAT_MAGIC_64`, with an architecture count no Java class
    /// file — which shares the magic — would carry.
    private static func isFatMagic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 8 else { return false }
        let magic = Array(bytes.prefix(4))
        guard magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xCA, 0xFE, 0xBA, 0xBF] else { return false }
        let architectureCount = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        return architectureCount > 0 && architectureCount < 32
    }

    /// A subcache — `dyld_shared_cache_arm64e.01`, `.symbols` — stands for the
    /// main cache file next to it.
    private static func mainCacheURL(for url: URL) -> URL {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty,
              pathExtension == "symbols" || pathExtension.allSatisfy(\.isNumber)
        else { return url }
        let mainURL = url.deletingPathExtension()
        return FileManager.default.fileExists(atPath: mainURL.path) ? mainURL : url
    }
}
