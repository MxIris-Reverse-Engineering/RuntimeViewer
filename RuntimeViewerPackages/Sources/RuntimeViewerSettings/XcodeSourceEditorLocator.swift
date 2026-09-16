#if os(macOS)

import AppKit
import Foundation

/// Finds the directory holding Xcode's private `SourceEditor` frameworks.
///
/// Shared between the loader that brings them up and the Settings UI that reports whether the
/// Xcode-backed content view can be used at all — otherwise the search order would be written
/// twice and the settings panel could confidently disagree with what the app actually does.
///
/// Locating them is all this does. Loading is the app's job, because that is where the code
/// which may not be linked lives.
public enum XcodeSourceEditorLocator {
    /// The display path's subset. `SymbolCache`, `SymbolCacheSupport` and `SymbolCacheIndexing`
    /// serve indexing and code completion; loading without them is verified to work.
    public static let requiredFrameworkNames = [
        "SourceEditor",
        "SourceModel",
        "SourceModelSupport",
        "_CodeCompletionFoundation",
    ]

    /// Where the frameworks were found, or `nil` if no candidate directory holds all of them.
    ///
    /// - Parameter preferredXcodeBundleURL: the `Xcode.app` the user picked in Settings, which
    ///   is tried ahead of everything else. `nil` restores the automatic order.
    public static func frameworksDirectory(preferring preferredXcodeBundleURL: URL? = nil) -> URL? {
        candidateDirectories(preferring: preferredXcodeBundleURL).first(where: containsAllRequiredFrameworks)
    }

    /// Copies embedded in the app win over Xcode's. That ordering is what reduces "do we ship
    /// these frameworks" to a packaging decision instead of a second code path.
    ///
    /// **An explicit choice outranks even the embedded copy.** Naming an Xcode and then being
    /// served a different editor is the one outcome the setting exists to prevent; the automatic
    /// order applies only when nothing was named.
    public static func candidateDirectories(preferring preferredXcodeBundleURL: URL? = nil) -> [URL] {
        var directories: [URL] = []

        if let preferredXcodeBundleURL {
            directories.append(sharedFrameworksDirectory(of: preferredXcodeBundleURL))
        }
        if let embedded = Bundle.main.privateFrameworksURL {
            directories.append(embedded)
        }
        if let installedXcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: xcodeBundleIdentifier) {
            directories.append(sharedFrameworksDirectory(of: installedXcode))
        }
        directories.append(sharedFrameworksDirectory(of: URL(fileURLWithPath: "/Applications/Xcode.app")))

        var seenPaths = Set<String>()
        return directories.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    public static func binaryURL(of frameworkName: String, in directory: URL) -> URL {
        directory.appending(path: "\(frameworkName).framework/Versions/A/\(frameworkName)")
    }

    public static func sharedFrameworksDirectory(of xcodeBundleURL: URL) -> URL {
        xcodeBundleURL.appending(path: "Contents/SharedFrameworks")
    }

    private static let xcodeBundleIdentifier = "com.apple.dt.Xcode"

    private static func containsAllRequiredFrameworks(in directory: URL) -> Bool {
        requiredFrameworkNames.allSatisfy { name in
            FileManager.default.fileExists(atPath: binaryURL(of: name, in: directory).path)
        }
    }

    // MARK: - What This Process Actually Loaded

    /// The directory the frameworks were loaded from *in this process*, or `nil` while none are
    /// loaded.
    ///
    /// Asked of dyld rather than of the loader, because the two questions have different answers
    /// and the Settings pane needs both: a stored choice describes the next launch, while this
    /// describes the editor the user is looking at right now. It also crosses no module boundary
    /// — the pane and the loader are in the same process but not in the same package.
    public static func loadedFrameworksDirectory() -> URL? {
        let suffix = "/SourceEditor.framework/Versions/A/SourceEditor"
        for imageIndex in 0 ..< _dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let path = String(cString: imageName)
            guard path.hasSuffix(suffix) else { continue }
            return URL(fileURLWithPath: String(path.dropLast(suffix.count)))
        }
        return nil
    }

    // MARK: - Installed Copies

    /// One installed Xcode, as the Settings picker lists it.
    public struct XcodeInstallation: Identifiable, Hashable, Sendable {
        public let bundleURL: URL

        /// `CFBundleShortVersionString`, or `nil` for a bundle whose `Info.plist` could not be
        /// read — which is not itself disqualifying, since only the frameworks decide that.
        public let version: String?

        /// Whether this copy actually holds all of ``requiredFrameworkNames``. A copy that does
        /// not is still listed, and still selectable, but the pane says so rather than letting
        /// the choice fail silently at the next launch.
        public let providesRequiredFrameworks: Bool

        /// The standardized path, which is also what ``Settings/Editor/sourceEditorXcodePath``
        /// stores — so a stored value matches exactly one row of the picker.
        public var id: String { bundleURL.standardizedFileURL.path }

        /// Two copies of one version are both installable, so the file name is part of the
        /// label rather than a fallback for when the version is missing.
        public var displayName: String {
            let fileName = bundleURL.deletingPathExtension().lastPathComponent
            guard let version else { return fileName }
            return "Xcode \(version) (\(fileName))"
        }

        public init(bundleURL: URL) {
            self.bundleURL = bundleURL.standardizedFileURL
            self.version = Bundle(url: bundleURL)?.infoDictionary?["CFBundleShortVersionString"] as? String
            self.providesRequiredFrameworks = containsAllRequiredFrameworks(
                in: XcodeSourceEditorLocator.sharedFrameworksDirectory(of: bundleURL)
            )
        }
    }

    /// Every Xcode LaunchServices knows about, newest first.
    ///
    /// LaunchServices is the only enumeration that finds copies outside `/Applications`, which
    /// is where a version manager puts them. It does miss one that was never launched or
    /// registered, which is what the Settings pane's "Other…" entry is for.
    public static func installedXcodes() -> [XcodeInstallation] {
        NSWorkspace.shared
            .urlsForApplications(withBundleIdentifier: xcodeBundleIdentifier)
            .map(XcodeInstallation.init(bundleURL:))
            .sorted { leading, trailing in
                let leadingVersion = leading.version ?? ""
                let trailingVersion = trailing.version ?? ""
                if leadingVersion != trailingVersion {
                    return leadingVersion.compare(trailingVersion, options: .numeric) == .orderedDescending
                }
                return leading.id < trailing.id
            }
    }
}

#endif
