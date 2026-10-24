public import Foundation
import MachOKit

/// The system a piece of derived data was produced on: what makes the images
/// of the dyld shared cache the ones it was produced from. Its
/// `directoryName` is the name of the directory that data is kept under, so
/// a system update — a new build, a new shared cache — finds nothing stored.
public struct RuntimeDerivedDataSystemIdentity: Hashable, Sendable {
    public enum Platform: String, Hashable, Sendable, CaseIterable {
        case macOS
        case macCatalyst
    }

    /// The platform of the process: a Mac Catalyst process reads the same
    /// shared cache through other images, `/System/iOSSupport` among them.
    public let platform: Platform

    /// `ProcessInfo.operatingSystemVersion`, such as "27.2" — for people
    /// reading the directory name; the build decides.
    public let operatingSystemVersion: String

    /// `sysctl kern.osversion`, such as "26B5112a".
    public let operatingSystemBuild: String

    /// `DyldCacheLoaded.current?.mainCacheHeader.uuid`.
    public let sharedCacheUUID: UUID

    public init(platform: Platform, operatingSystemVersion: String, operatingSystemBuild: String, sharedCacheUUID: UUID) {
        self.platform = platform
        self.operatingSystemVersion = Self.directoryNameComponent(operatingSystemVersion)
        self.operatingSystemBuild = Self.directoryNameComponent(operatingSystemBuild)
        self.sharedCacheUUID = sharedCacheUUID
    }

    /// "<platform>-<version>-<build>-<shared cache UUID>".
    public var directoryName: String {
        "\(platform.rawValue)-\(operatingSystemVersion)-\(operatingSystemBuild)-\(sharedCacheUUID.uuidString)"
    }

    /// This process's system; `nil` when the process maps no shared cache,
    /// cannot read its build, or runs on a platform derived data does not
    /// serve.
    public static func current() -> RuntimeDerivedDataSystemIdentity? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        guard let sharedCache = DyldCacheLoaded.current,
              let operatingSystemBuild = Self.kernelString(named: "kern.osversion"), !operatingSystemBuild.isEmpty
        else { return nil }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return RuntimeDerivedDataSystemIdentity(
            // A runtime question, not `targetEnvironment(macCatalyst)`: the
            // Mac Catalyst service runs this code from a plug-in built for
            // macOS.
            platform: ProcessInfo.processInfo.isMacCatalystApp ? .macCatalyst : .macOS,
            operatingSystemVersion: versionString,
            operatingSystemBuild: operatingSystemBuild,
            sharedCacheUUID: sharedCache.mainCacheHeader.uuid
        )
        #else
        return nil
        #endif
    }

    /// The build in a name `directoryName` made, `nil` for any other name —
    /// what the cleanup decides a system directory by.
    static func operatingSystemBuild(ofDirectoryNamed directoryName: String) -> String? {
        let components = directoryName.split(separator: "-", omittingEmptySubsequences: false)
        // The UUID string itself holds four hyphens.
        guard components.count == 8,
              Platform(rawValue: String(components[0])) != nil,
              UUID(uuidString: components[3...].joined(separator: "-")) != nil,
              !components[2].isEmpty
        else { return nil }
        return String(components[2])
    }

    /// Letters, digits and dots only, so a name always splits back into its
    /// four parts.
    private static func directoryNameComponent(_ string: String) -> String {
        String(string.map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == ".") ? character : "_"
        })
    }

    private static func kernelString(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
