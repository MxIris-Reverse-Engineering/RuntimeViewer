#if os(macOS)

import Foundation

/// A payload slice this build of RuntimeViewer ships and can inject.
///
/// Deliberately narrower than ``InjectionTargetPlatform``: that one describes
/// what a target *is*, this one what we have to offer it. A tvOS Simulator
/// process is a perfectly readable target with no slice to give it, and the gap
/// between the two enumerations is where that refusal gets made — explicitly,
/// rather than by handing over the nearest slice and letting dyld sort it out.
public enum PayloadPlatform: Sendable, Hashable, CaseIterable {
    case macOS
    case iOSSimulator

    /// The slice a target platform can load, or `nil` when this build ships
    /// none for it.
    public init?(targetPlatform: InjectionTargetPlatform) {
        switch targetPlatform {
        case .macOS, .macCatalyst:
            // Catalyst runs on the host's dyld and shared cache and has always
            // been given the macOS slice; this keeps that behaviour rather than
            // changing it on the way past.
            self = .macOS
        case .iOSSimulator:
            self = .iOSSimulator
        case .tvOSSimulator, .watchOSSimulator, .visionOSSimulator, .unsupported:
            return nil
        }
    }

    /// The bundle name under `Bundle.main` and under `/Library/Frameworks`.
    ///
    /// The two slices are the same architecture and differ only in platform, so
    /// a single fat binary cannot hold both — they ship and install as sibling
    /// bundles instead. Each is named after the scheme that produces it, so the
    /// bundle sitting in `/Library/Frameworks` says which build it came from.
    public var frameworkBundleBaseName: String {
        switch self {
        case .macOS: return "RuntimeViewerServer"
        case .iOSSimulator: return "RuntimeViewerMobileServer"
        }
    }

    public var frameworkBundleName: String {
        "\(frameworkBundleBaseName).framework"
    }

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .iOSSimulator: return "iOS Simulator"
        }
    }

    // MARK: - Install location

    /// Where installed payloads live.
    ///
    /// A simulator process reaches this despite `dyld_sim` rewriting the path:
    /// it probes `<RuntimeRoot>/Library/Frameworks/…` first and the host's own
    /// `/Library/Frameworks/…` second, so an absolute host path still resolves.
    /// (Measured against a live iOS 18.5 simulator daemon, 2026-08-23; every
    /// prefix tried behaved the same way, so the choice of directory is free.)
    public static let installDirectoryURL = URL(fileURLWithPath: "/Library/Frameworks")

    public var installedFrameworkURL: URL {
        Self.installDirectoryURL.appendingPathComponent(frameworkBundleName)
    }
}

extension InjectionTargetPlatform {
    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .macCatalyst: return "Mac Catalyst"
        case .iOSSimulator: return "iOS Simulator"
        case .tvOSSimulator: return "tvOS Simulator"
        case .watchOSSimulator: return "watchOS Simulator"
        case .visionOSSimulator: return "visionOS Simulator"
        case .unsupported(let value): return "platform \(value)"
        }
    }
}

#endif
