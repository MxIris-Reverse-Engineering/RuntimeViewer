import Foundation
import ProjectDescription

/// Resolves a dependency either to the cached external package or to a local
/// checkout, mirroring the `USING_LOCAL_DEPENDENCIES` switch that the packages'
/// own `Package.swift` manifests implement.
///
/// Two manifest layers read *differently named* variables, and both must be set
/// when working against local checkouts:
///
/// | manifest                       | reads                 | variable                        |
/// |--------------------------------|-----------------------|---------------------------------|
/// | `Tuist/Package.swift` (SwiftPM)| `Context.environment` | `USING_LOCAL_DEPENDENCIES`      |
/// | `Project.swift` (Tuist)        | `Environment`         | `TUIST_USING_LOCAL_DEPENDENCIES`|
///
/// Tuist only forwards `TUIST_`-prefixed variables into manifest evaluation, so
/// the unprefixed name is invisible here — reading it yields nothing regardless
/// of whether it is exported.
public enum LocalDependencies {
    /// Whether local checkouts should be preferred over the resolved external packages.
    public static var isEnabled: Bool {
        Environment.usingLocalDependencies.getBoolean(default: false)
    }

    /// Whether `relativePath` (resolved against `manifestDirectory`) exists *and*
    /// local dependencies are enabled.
    ///
    /// The existence check is what makes this safe to declare unconditionally: a
    /// checkout that is not present simply falls back to the external package,
    /// which is exactly how `Package.swift` behaves.
    public static func isAvailable(_ relativePath: String, from manifestDirectory: String) -> Bool {
        guard isEnabled else { return false }
        let resolved = URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: manifestDirectory)).path
        return FileManager.default.fileExists(atPath: resolved)
    }

    /// A dependency on `productName`, taken from the local checkout when available
    /// and from the cached external package otherwise.
    public static func dependency(
        productName: String,
        localPath: String,
        manifestDirectory: String
    ) -> TargetDependency {
        isAvailable(localPath, from: manifestDirectory)
            ? .package(product: productName)
            : .external(name: productName)
    }

    /// The `packages:` entries matching whichever dependencies resolved to a local
    /// checkout. Must be kept in sync with the `dependency(productName:…)` calls —
    /// a `.package(product:)` dependency without its local package declared here
    /// fails generation.
    public static func packages(_ entries: [(path: String, manifestDirectory: String)]) -> [Package] {
        entries.compactMap { entry in
            isAvailable(entry.path, from: entry.manifestDirectory)
                ? .local(path: .relativeToManifest(entry.path))
                : nil
        }
    }
}
