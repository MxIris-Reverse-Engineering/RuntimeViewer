#if os(macOS)

import Foundation
import MachO

/// The reconstructed `SourceEditor` frameworks, which official builds carry inside the app.
///
/// They come from the releases of the private `Mx-Iris/SourceEditor` repository, a rebuild of the
/// Xcode 26.6 frameworks of the same names: `FetchSourceEditorScript.sh` downloads the pinned
/// release, the app links it directly, and the app's *Embed SourceEditor Frameworks* phase copies
/// it into `Contents/Frameworks`. A build made without access to that repository carries none of
/// them, compiles its SourceEditor code out, and shows interfaces in the built-in `NSTextView`.
///
/// Read by the code outside the app target that has to know which editor this build uses — the
/// Settings UI and the comment tags — without importing anything from it.
public enum SourceEditorFrameworks {
    /// What this build can do with the frameworks.
    public enum Availability: Equatable, Sendable {
        /// The app carries all of ``names``, built for the architecture this process runs as.
        case available(directory: URL)

        /// The app carries none of them, or not all of them: any build made without access to the
        /// private repository.
        case notEmbedded

        /// The app carries them, but not for this architecture. The releases are arm64 only, so an
        /// Intel Mac shows interfaces in the built-in text view.
        case unsupportedArchitecture
    }

    /// The display path's subset of the family. `SourceEditorRegExSupport` is not among them:
    /// nothing the app shows needs it, and none of these four depends on it.
    public static let names = [
        "SourceEditor",
        "SourceModel",
        "SourceModelSupport",
        "_CodeCompletionFoundation",
    ]

    /// Resolved once per process: the app bundle does not change while it runs.
    public static let availability = resolveAvailability(in: .main)

    public static func binaryURL(of frameworkName: String, in directory: URL) -> URL {
        directory.appending(path: "\(frameworkName).framework/Versions/A/\(frameworkName)")
    }

    static func resolveAvailability(in bundle: Bundle) -> Availability {
        guard let directory = bundle.privateFrameworksURL, containsAllFrameworks(in: directory) else {
            return .notEmbedded
        }
        let supportsRunningArchitecture = names.allSatisfy { name in
            Bundle(url: directory.appending(path: "\(name).framework")).map(supportsRunningArchitecture) ?? false
        }
        guard supportsRunningArchitecture else {
            return .unsupportedArchitecture
        }
        return .available(directory: directory)
    }

    static func containsAllFrameworks(in directory: URL) -> Bool {
        names.allSatisfy { name in
            FileManager.default.fileExists(atPath: binaryURL(of: name, in: directory).path)
        }
    }

    /// Reads the architectures out of the executable's header, without loading it.
    static func supportsRunningArchitecture(_ bundle: Bundle) -> Bool {
        guard let architectures = bundle.executableArchitectures else { return false }
        return architectures.contains { $0.intValue == runningArchitecture }
    }

    private static var runningArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    // MARK: - The Loaded Copy

    /// Which copy of the frameworks a process runs on.
    ///
    /// A build normally runs on the reconstruction it carries. `LaunchWithXcodeSourceEditorScript.sh`
    /// starts a Debug build on Xcode 26.6's originals instead, by pointing `DYLD_FRAMEWORK_PATH` —
    /// which dyld searches before any rpath — at links to them; Settings › Developer shows which of
    /// the two an instance runs on, so that two instances side by side are not mistaken for each other.
    public enum LoadedCopy: Equatable, Sendable {
        /// The reconstruction in the app's own `Contents/Frameworks`.
        case embedded

        /// An Xcode's own copy, from its `Contents/SharedFrameworks`. The version is the Xcode's
        /// `CFBundleShortVersionString`, nil when its `Info.plist` cannot be read.
        case xcode(bundleURL: URL, version: String?)

        /// Anything else, named by the directory holding the frameworks.
        case other(directory: URL)
    }

    /// The copy this process runs on, or nil when it has loaded none: a build without the
    /// frameworks, or the Intel slice. dyld maps them before `main`, so this does not change while
    /// the process runs.
    public static let loadedCopy: LoadedCopy? = loadedBinaryPath().flatMap { binaryPath in
        loadedCopy(forBinaryAt: binaryPath, embeddedDirectory: Bundle.main.privateFrameworksURL)
    }

    /// Where `SourceEditor`'s binary sits relative to the directory holding the frameworks.
    private static let binaryPathSuffix = "/SourceEditor.framework/Versions/A/SourceEditor"

    /// The path dyld loaded `SourceEditor` from: the path it opened, so through the script's links
    /// rather than into the Xcode they point to.
    static func loadedBinaryPath() -> String? {
        for imageIndex in 0 ..< _dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let imagePath = String(cString: imageName)
            if imagePath.hasSuffix(binaryPathSuffix) {
                return imagePath
            }
        }
        return nil
    }

    /// Classifies a loaded `SourceEditor` binary by where it really is, links resolved, against the
    /// app's own frameworks directory. Nil for a path that is not that binary.
    static func loadedCopy(forBinaryAt binaryPath: String, embeddedDirectory: URL?) -> LoadedCopy? {
        let resolvedBinaryPath = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        guard binaryPath.hasSuffix(binaryPathSuffix), resolvedBinaryPath.hasSuffix(binaryPathSuffix) else {
            return nil
        }
        let directory = URL(fileURLWithPath: String(resolvedBinaryPath.dropLast(binaryPathSuffix.count)), isDirectory: true)
        if let embeddedDirectory, directory.path == embeddedDirectory.resolvingSymlinksInPath().path {
            return .embedded
        }
        let contentsDirectory = directory.deletingLastPathComponent()
        let bundleURL = contentsDirectory.deletingLastPathComponent()
        if directory.lastPathComponent == "SharedFrameworks", contentsDirectory.lastPathComponent == "Contents", bundleURL.pathExtension == "app" {
            let infoDictionary = NSDictionary(contentsOf: contentsDirectory.appending(path: "Info.plist"))
            return .xcode(bundleURL: bundleURL, version: infoDictionary?["CFBundleShortVersionString"] as? String)
        }
        return .other(directory: directory)
    }
}

#endif
