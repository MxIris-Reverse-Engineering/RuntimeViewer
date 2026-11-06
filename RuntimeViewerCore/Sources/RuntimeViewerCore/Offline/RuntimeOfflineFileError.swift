public import Foundation
import RuntimeViewerCommunication
import MachOKit
import MachODependencies

/// Why a file cannot be opened offline.
public enum RuntimeOfflineFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(URL)
    case unsupportedContent(URL)
    case bundleWithoutExecutable(URL)
    /// A folder with no executable, dynamic library or bundle inside it or
    /// below it.
    case folderWithoutMachOFiles(URL)
    case noSupportedSlice(URL)
    case dependencyCacheUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            "“\(url.lastPathComponent)” cannot be read."
        case .unsupportedContent(let url):
            "“\(url.lastPathComponent)” is not a Mach-O file, a bundle or a dyld shared cache."
        case .bundleWithoutExecutable(let url):
            "The bundle “\(url.lastPathComponent)” has no executable."
        case .folderWithoutMachOFiles(let url):
            "The folder “\(url.lastPathComponent)” holds no executable, library or bundle."
        case .noSupportedSlice(let url):
            "“\(url.lastPathComponent)” has no slice this Mac can read."
        case .dependencyCacheUnavailable(let description):
            "The dyld shared cache to read dependencies from cannot be opened: \(description)."
        }
    }
}
