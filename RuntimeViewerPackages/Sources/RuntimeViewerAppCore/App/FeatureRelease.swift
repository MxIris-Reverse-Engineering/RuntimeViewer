#if os(macOS)

import Foundation

/// A feature release of the app: the major and minor parts of its marketing version.
///
/// The betas and the patch releases of one feature release share its onboarding pages. Every beta of
/// 3.0.0 reports `3.0.0` and differs only in its build number, and a patch release has no new features to
/// show, so What's New appears once per feature release (proposal `onboarding-pages`).
public struct FeatureRelease: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// `3.0.0`, `3.0` and `3.0.1` are all 3.0. `nil` when the string does not start with two numbers
    /// separated by a dot.
    public init?(marketingVersion: String) {
        let components = marketingVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let major = Int(components[0]), major >= 0,
              let minor = Int(components[1]), minor >= 0
        else { return nil }
        self.init(major: major, minor: minor)
    }

    /// `3.0`.
    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: FeatureRelease, rhs: FeatureRelease) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

#endif
