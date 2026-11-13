import Foundation

/// Decides which releases in the update feed may be offered to the running app.
///
/// Sparkle orders releases by build number alone: it compares the app's `CFBundleVersion` with each
/// feed item's `sparkle:version`. Release builds carry a date-based build number, so that order is
/// the version order, but a plain Xcode build reports `1` (`Configurations/Version.xcconfig`), which
/// every published build outranks — such a build was offered any release in the feed, older versions
/// included. This policy checks the version users see as well, before Sparkle compares builds.
public struct UpdateEligibility: Sendable, Equatable {
    /// The build number `Configurations/Version.xcconfig` gives a build that `RunScript.sh` or
    /// `ArchiveScript.sh` did not number, which is any build started from Xcode.
    public static let developmentBuildNumber = "1"

    /// The running app's `CFBundleShortVersionString`.
    public let currentVersion: String

    /// The running app's `CFBundleVersion`.
    public let currentBuildNumber: String

    public init(currentVersion: String, currentBuildNumber: String) {
        self.currentVersion = currentVersion
        self.currentBuildNumber = currentBuildNumber
    }

    /// The policy for the app `bundle` belongs to, or `nil` when its `Info.plist` lacks either version.
    public static func runningApplication(bundle: Bundle = .main) -> UpdateEligibility? {
        guard let informationDictionary = bundle.infoDictionary,
              let currentVersion = informationDictionary["CFBundleShortVersionString"] as? String,
              let currentBuildNumber = informationDictionary["CFBundleVersion"] as? String
        else { return nil }
        return UpdateEligibility(currentVersion: currentVersion, currentBuildNumber: currentBuildNumber)
    }

    /// Whether the running app is a build nobody numbered: its build number says nothing about how it
    /// relates to the published builds of its version.
    public var isDevelopmentBuild: Bool {
        currentBuildNumber == Self.developmentBuildNumber
    }

    /// Whether a release whose `CFBundleShortVersionString` is `version` may be offered.
    ///
    /// A numbered build accepts its own version or a later one, and Sparkle's build number comparison
    /// then decides between builds of one version. A development build is built from the working tree,
    /// which is newer than every published build of its version, so it only accepts a later version.
    public func allowsUpdate(toVersion version: String) -> Bool {
        let order = Self.compareVersions(version, currentVersion)
        return isDevelopmentBuild ? order == .orderedDescending : order != .orderedAscending
    }

    /// Orders two dotted versions component by component, as numbers; a missing component counts as 0,
    /// and so does anything after a component's leading digits ("3.0" equals "3.0.0").
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsComponents = numericComponents(of: lhs)
        let rhsComponents = numericComponents(of: rhs)
        for index in 0..<max(lhsComponents.count, rhsComponents.count) {
            let lhsComponent = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsComponent = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsComponent < rhsComponent { return .orderedAscending }
            if lhsComponent > rhsComponent { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericComponents(of version: String) -> [Int] {
        version.split(separator: ".").map { component in
            Int(component.prefix(while: { $0.isASCII && $0.isNumber })) ?? 0
        }
    }
}
