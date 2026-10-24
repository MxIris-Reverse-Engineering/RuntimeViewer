public import Foundation

/// Where the derived data of one RuntimeViewer application lives:
/// `~/Library/Caches/<bundle identifier>/DerivedData`.
///
/// Caches, because everything in it can be produced again, and Time Machine
/// leaves it out. One directory per bundle identifier, which tells the
/// configurations apart — Debug, Debug-arm64e and Release each have their
/// own — while the builds sharing a configuration share it and keep apart by
/// producer (`RuntimeDerivedDataProducerIdentity`).
///
/// The app and the two services it embeds all come to the same place: each
/// starts from its own bundle and finds the application around it.
public struct RuntimeDerivedDataLocation: Hashable, Sendable {
    /// The RuntimeViewer application this is the derived data of.
    public let applicationURL: URL

    /// `~/Library/Caches/<bundle identifier>/DerivedData`.
    public let rootURL: URL

    public init(applicationURL: URL, rootURL: URL) {
        self.applicationURL = applicationURL
        self.rootURL = rootURL
    }

    static let rootDirectoryName = "DerivedData"

    /// What a deletion renames the root to before it deletes it, followed by
    /// a UUID; the cleanup removes any it finds.
    static let deletingRootDirectoryNamePrefix = "DerivedData.deleting-"

    /// The `.app` enclosing `bundle` — the bundle itself, or an XPC service
    /// under its `Contents/XPCServices` — when the application's `Info.plist`
    /// names `RuntimeViewerLocalRuntimeServiceBundleIdentifier`; `nil`
    /// anywhere else.
    public static func enclosingApplication(of bundle: Bundle) -> RuntimeDerivedDataLocation? {
        guard let cachesDirectoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return enclosingApplication(ofBundleAt: bundle.bundleURL, cachesDirectoryURL: cachesDirectoryURL)
    }

    /// `enclosingApplication(of:)` for the bundle at `bundleURL`, the caches
    /// directory given.
    static func enclosingApplication(ofBundleAt bundleURL: URL, cachesDirectoryURL: URL) -> RuntimeDerivedDataLocation? {
        let bundleURL = bundleURL.standardizedFileURL
        let applicationURL: URL
        if bundleURL.pathExtension == "app" {
            applicationURL = bundleURL
        } else {
            let servicesDirectoryURL = bundleURL.deletingLastPathComponent()
            let contentsDirectoryURL = servicesDirectoryURL.deletingLastPathComponent()
            guard servicesDirectoryURL.lastPathComponent == "XPCServices",
                  contentsDirectoryURL.lastPathComponent == "Contents"
            else { return nil }
            applicationURL = contentsDirectoryURL.deletingLastPathComponent()
        }
        guard applicationURL.pathExtension == "app",
              let infoData = try? Data(contentsOf: applicationURL.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let serviceBundleIdentifier = info[LocalRuntimeService.bundleIdentifierInfoDictionaryKey] as? String, !serviceBundleIdentifier.isEmpty,
              let bundleIdentifier = info["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty,
              !bundleIdentifier.contains("/")
        else { return nil }
        return RuntimeDerivedDataLocation(
            applicationURL: applicationURL,
            rootURL: cachesDirectoryURL
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent(rootDirectoryName, isDirectory: true)
        )
    }
}
