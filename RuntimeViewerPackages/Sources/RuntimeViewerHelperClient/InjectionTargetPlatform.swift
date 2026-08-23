#if os(macOS)

import Foundation

/// The platform a process was built for, which decides which payload slice it
/// can load.
///
/// A macOS process and an iOS Simulator process on the same Mac are the same
/// `cputype` — `arm64` on Apple silicon, `x86_64` on Intel — and differ only in
/// the `platform` field of their `LC_BUILD_VERSION`. A fat binary cannot hold
/// both (that is what an `.xcframework` exists for), so the payload must be
/// built and delivered per platform, and the delivery has to know which one the
/// target is.
///
/// Getting this wrong is not a soft failure. dyld refuses the mismatched slice,
/// and the injector's fallback path then projects the payload into the target
/// with `mach_vm_remap`, which the kernel kills on page-in.
public enum InjectionTargetPlatform: Sendable, Hashable {
    case macOS
    case macCatalyst
    case iOSSimulator
    case tvOSSimulator
    case watchOSSimulator
    case visionOSSimulator

    /// A platform this build has no payload slice for. Carries the raw
    /// `LC_BUILD_VERSION` value so a refusal can name it.
    case unsupported(UInt32)

    /// Whether the target runs under `dyld_sim` rather than the host's dyld.
    public var isSimulator: Bool {
        switch self {
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator, .visionOSSimulator:
            return true
        case .macOS, .macCatalyst, .unsupported:
            return false
        }
    }
}

/// Reads a target's platform out of its executable's Mach-O headers.
///
/// Deliberately not derived from the executable's path. The RuntimeRoot prefix
/// (`…/iOS 18.5.simruntime/Contents/Resources/RuntimeRoot/…`) identifies the
/// system daemons a simulator boots, but an app the user built and installed
/// runs from the device's data container and carries no such marker. The load
/// command is the only answer that covers both.
public enum InjectionTargetPlatformProbe {
    /// The platform of the process with this pid, or `nil` when the executable
    /// cannot be located or parsed.
    ///
    /// A `nil` here means "unknown", not "macOS" — the caller decides whether
    /// an unreadable target is worth attempting.
    public static func platform(ofProcess processIdentifier: pid_t) -> InjectionTargetPlatform? {
        guard let executableURL = executableURL(ofProcess: processIdentifier) else { return nil }
        return platform(ofMachOFileAt: executableURL)
    }

    /// The executable path of a running process, via `proc_pidpath`.
    public static func executableURL(ofProcess processIdentifier: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
    }

    /// The platform recorded in a Mach-O file's `LC_BUILD_VERSION`.
    ///
    /// For a fat binary, every slice is inspected and the first recognized
    /// platform wins. Slices of one file never disagree in practice: a fat
    /// binary holds several architectures of a single build, and the case where
    /// platforms genuinely differ — a macOS slice beside an iOS Simulator one —
    /// is what an `.xcframework` splits into separate files precisely because a
    /// fat binary cannot express it.
    public static func platform(ofMachOFileAt url: URL) -> InjectionTargetPlatform? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        return data.withUnsafeBytes { buffer -> InjectionTargetPlatform? in
            guard let magic: UInt32 = buffer.loadUnalignedIfWithinBounds(byteOffset: 0, as: UInt32.self) else {
                return nil
            }

            switch magic {
            case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
                return platformOfFatFile(buffer, magic: magic)
            default:
                return platformOfThinFile(buffer, atOffset: 0)
            }
        }
    }

    // MARK: - Fat files

    private static func platformOfFatFile(
        _ buffer: UnsafeRawBufferPointer,
        magic: UInt32
    ) -> InjectionTargetPlatform? {
        let is64Bit = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
        // Fat headers are always big-endian, whatever the host is.
        guard let architectureCount: UInt32 = buffer.loadUnalignedIfWithinBounds(byteOffset: 4, as: UInt32.self) else {
            return nil
        }
        let count = Int(architectureCount.bigEndian)
        // A corrupt or hostile count must not turn into a huge loop; each entry
        // is bounds-checked below anyway, but cap the iteration up front.
        guard count > 0, count < 64 else { return nil }

        let entrySize = is64Bit ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        // `offset` is the third field of both fat_arch and fat_arch_64, after
        // cputype and cpusubtype; it widens to 64 bits in the _64 variant.
        let offsetFieldOffset = MemoryLayout<UInt32>.size * 2

        for index in 0 ..< count {
            let entryOffset = MemoryLayout<fat_header>.size + index * entrySize
            let sliceOffset: Int
            if is64Bit {
                guard let rawOffset: UInt64 = buffer.loadUnalignedIfWithinBounds(
                    byteOffset: entryOffset + offsetFieldOffset,
                    as: UInt64.self
                ) else { return nil }
                sliceOffset = Int(rawOffset.bigEndian)
            } else {
                guard let rawOffset: UInt32 = buffer.loadUnalignedIfWithinBounds(
                    byteOffset: entryOffset + offsetFieldOffset,
                    as: UInt32.self
                ) else { return nil }
                sliceOffset = Int(rawOffset.bigEndian)
            }

            if let platform = platformOfThinFile(buffer, atOffset: sliceOffset) {
                return platform
            }
        }
        return nil
    }

    // MARK: - Thin files

    private static func platformOfThinFile(
        _ buffer: UnsafeRawBufferPointer,
        atOffset fileOffset: Int
    ) -> InjectionTargetPlatform? {
        guard fileOffset >= 0,
              let magic: UInt32 = buffer.loadUnalignedIfWithinBounds(byteOffset: fileOffset, as: UInt32.self)
        else { return nil }

        let is64Bit: Bool
        let needsSwap: Bool
        switch magic {
        case MH_MAGIC_64: is64Bit = true;  needsSwap = false
        case MH_CIGAM_64: is64Bit = true;  needsSwap = true
        case MH_MAGIC:    is64Bit = false; needsSwap = false
        case MH_CIGAM:    is64Bit = false; needsSwap = true
        default: return nil
        }

        func normalize(_ value: UInt32) -> UInt32 { needsSwap ? value.byteSwapped : value }

        // ncmds and sizeofcmds are the fifth and sixth UInt32 of mach_header.
        guard let commandCount: UInt32 = buffer.loadUnalignedIfWithinBounds(
            byteOffset: fileOffset + MemoryLayout<UInt32>.size * 4,
            as: UInt32.self
        ) else { return nil }

        let headerSize = is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        var commandOffset = fileOffset + headerSize
        var fallbackPlatform: InjectionTargetPlatform?

        for _ in 0 ..< normalize(commandCount) {
            guard let command: UInt32 = buffer.loadUnalignedIfWithinBounds(byteOffset: commandOffset, as: UInt32.self),
                  let commandSize: UInt32 = buffer.loadUnalignedIfWithinBounds(
                      byteOffset: commandOffset + MemoryLayout<UInt32>.size,
                      as: UInt32.self
                  )
            else { return fallbackPlatform }

            let size = Int(normalize(commandSize))
            // A zero or negative size would spin forever on a malformed file.
            guard size >= MemoryLayout<load_command>.size else { return fallbackPlatform }

            switch normalize(command) {
            case UInt32(LC_BUILD_VERSION):
                guard let rawPlatform: UInt32 = buffer.loadUnalignedIfWithinBounds(
                    byteOffset: commandOffset + MemoryLayout<UInt32>.size * 2,
                    as: UInt32.self
                ) else { return fallbackPlatform }
                return platform(forLoadCommandValue: normalize(rawPlatform))

            // Binaries predating LC_BUILD_VERSION carry only a minimum-OS
            // command. Kept as a fallback rather than an immediate answer
            // because a binary can carry both, and LC_BUILD_VERSION is the
            // authoritative one when it does.
            case UInt32(LC_VERSION_MIN_MACOSX):
                fallbackPlatform = .macOS
            // A device binary cannot execute on a Mac at all, so an iOS/tvOS/
            // watchOS minimum-OS command on a live local process means the
            // simulator by elimination.
            case UInt32(LC_VERSION_MIN_IPHONEOS):
                fallbackPlatform = .iOSSimulator
            case UInt32(LC_VERSION_MIN_TVOS):
                fallbackPlatform = .tvOSSimulator
            case UInt32(LC_VERSION_MIN_WATCHOS):
                fallbackPlatform = .watchOSSimulator
            default:
                break
            }

            commandOffset += size
        }
        return fallbackPlatform
    }

    /// Maps a raw `LC_BUILD_VERSION` platform value onto the payload slices this
    /// app ships. The constants are from `<mach-o/loader.h>`; they are spelled
    /// out because the header exposes them as macros, which do not reach Swift.
    static func platform(forLoadCommandValue value: UInt32) -> InjectionTargetPlatform {
        switch value {
        case 1: return .macOS                 // PLATFORM_MACOS
        case 6: return .macCatalyst           // PLATFORM_MACCATALYST
        case 7: return .iOSSimulator          // PLATFORM_IOSSIMULATOR
        case 8: return .tvOSSimulator         // PLATFORM_TVOSSIMULATOR
        case 9: return .watchOSSimulator      // PLATFORM_WATCHOSSIMULATOR
        case 11: return .visionOSSimulator    // PLATFORM_XROS_SIMULATOR
        default: return .unsupported(value)
        }
    }
}

// MARK: -

extension UnsafeRawBufferPointer {
    /// `loadUnaligned` that answers `nil` instead of trapping when the read
    /// would run past the end of the buffer.
    ///
    /// The payload here is a file the user pointed us at — a truncated or
    /// hostile Mach-O must produce "cannot tell" rather than crash the app.
    fileprivate func loadUnalignedIfWithinBounds<Value>(
        byteOffset: Int,
        as type: Value.Type
    ) -> Value? {
        guard byteOffset >= 0, byteOffset + MemoryLayout<Value>.size <= count else { return nil }
        return loadUnaligned(fromByteOffset: byteOffset, as: type)
    }
}

#endif
