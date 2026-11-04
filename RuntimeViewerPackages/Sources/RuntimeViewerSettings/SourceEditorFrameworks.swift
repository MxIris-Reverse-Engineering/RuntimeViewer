#if os(macOS)

import Foundation

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
}

#endif
