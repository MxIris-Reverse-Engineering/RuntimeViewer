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
    public static func frameworksDirectory() -> URL? {
        candidateDirectories().first(where: containsAllRequiredFrameworks)
    }

    /// Copies embedded in the app win over Xcode's. That ordering is what reduces "do we ship
    /// these frameworks" to a packaging decision instead of a second code path.
    public static func candidateDirectories() -> [URL] {
        var directories: [URL] = []

        if let embedded = Bundle.main.privateFrameworksURL {
            directories.append(embedded)
        }
        if let installedXcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            directories.append(installedXcode.appending(path: "Contents/SharedFrameworks"))
        }
        directories.append(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/SharedFrameworks"))

        var seenPaths = Set<String>()
        return directories.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
    }

    public static func binaryURL(of frameworkName: String, in directory: URL) -> URL {
        directory.appending(path: "\(frameworkName).framework/Versions/A/\(frameworkName)")
    }

    private static func containsAllRequiredFrameworks(in directory: URL) -> Bool {
        requiredFrameworkNames.allSatisfy { name in
            FileManager.default.fileExists(atPath: binaryURL(of: name, in: directory).path)
        }
    }
}

#endif
