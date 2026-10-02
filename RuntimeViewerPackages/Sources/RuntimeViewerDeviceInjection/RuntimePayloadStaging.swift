public import Foundation

/// Lays out a copy of the injection payload somewhere a target process can load
/// it from.
///
/// Deliberately not gated on iOS, although only the device injection service
/// uses it: the layout it produces is the one thing here that a target process
/// silently refuses when it is wrong, and a `dlopen` failure inside someone
/// else's process is the hardest place in this feature to see a mistake. Kept
/// platform-neutral, it is exercised by the tests on macOS instead — the same
/// reasoning that keeps `RuntimeDeviceProcessEnumerator` cross-platform.
public struct RuntimePayloadStaging {
    /// The subdirectory the payload's `@rpath` dependencies have to land in.
    ///
    /// Not a free choice: the payload records `@loader_path/Frameworks` among
    /// its run-path search paths, and the loader is the staged copy. A
    /// directory of this exact name beside it is what makes the dependencies
    /// resolvable without rewriting the binary.
    public static let dependencyDirectoryName = "Frameworks"

    /// The Mach-O to load into the target. Not the `.framework` wrapper around
    /// it — `dlopen` of a directory fails.
    public let payloadURL: URL

    /// The directory holding the libraries the payload loads through `@rpath`,
    /// normally the hosting app's `Frameworks`.
    ///
    /// Passed in rather than derived from `payloadURL`'s enclosing directories:
    /// deriving it would couple this type to wherever the payload happens to be
    /// embedded, and get it wrong without saying so.
    public let dependencyDirectoryURL: URL

    /// Where the payload and its dependencies are copied.
    ///
    /// The target has to be able to map the files, and it is a different
    /// process with a different view of the filesystem than the app bundle's. A
    /// world-readable path outside any container is the only thing both sides
    /// agree on.
    public let stagingDirectoryURL: URL

    private let fileManager: FileManager

    public init(
        payloadURL: URL,
        dependencyDirectoryURL: URL,
        stagingDirectoryURL: URL,
        fileManager: FileManager = .default,
    ) {
        self.payloadURL = payloadURL
        self.dependencyDirectoryURL = dependencyDirectoryURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.fileManager = fileManager
    }

    /// Copies the payload and everything it loads through `@rpath`, and returns
    /// the path to hand the injector.
    ///
    /// The dependencies are not optional. The payload links
    /// `@rpath/libswiftCompatibilitySpan.dylib` — a Swift back-deployment shim
    /// Xcode embeds in the app bundle because the deployment target predates the
    /// release that folded `Span` into `libswiftCore`. Its first run-path entry
    /// is `/usr/lib/swift`, so on a system that happens to ship the shim a lone
    /// staged copy would load with nothing else present, and that is exactly
    /// what makes relying on it a trap: measured, iOS 26.5 ships
    /// `/usr/lib/swift/libswiftCompatibilitySpan.dylib` and **iOS 27 does
    /// not**, the SDK stub there having become an alias for `libswiftCore`.
    /// macOS 27 still ships it, which is why the host's own injection path
    /// never had to deal with this.
    @discardableResult
    public func stage() throws -> URL {
        let stagedPayloadURL = stagingDirectoryURL.appendingPathComponent(payloadURL.lastPathComponent)
        let stagedDependencyDirectoryURL = stagingDirectoryURL.appendingPathComponent(
            Self.dependencyDirectoryName,
            isDirectory: true,
        )

        // The directory is created rather than cleared wholesale: a caller may
        // have pointed this at a path holding other things, and removing only
        // what is about to be rewritten keeps that from mattering.
        try createDirectory(at: stagingDirectoryURL)
        try removeItemIfPresent(at: stagedPayloadURL)
        try removeItemIfPresent(at: stagedDependencyDirectoryURL)

        try fileManager.copyItem(at: payloadURL, to: stagedPayloadURL)
        // The target maps the file, so it needs read and execute. This process's
        // umask would otherwise leave it readable only by this uid, and the
        // target is frequently a different one.
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedPayloadURL.path)

        try stageDependencies(into: stagedDependencyDirectoryURL)
        return stagedPayloadURL
    }

    /// Copies the hosting app's embedded libraries beside the staged payload.
    ///
    /// Everything in the directory is copied except the payload's own bundle,
    /// rather than the one library the payload is known to need. Reading the
    /// payload's load commands to copy the exact set would be more precise and
    /// is the wrong trade here: a few hundred kilobytes of unused libraries cost
    /// nothing against a dependency added upstream later and noticed only as a
    /// `dlopen` failure inside another process.
    private func stageDependencies(into destinationURL: URL) throws {
        let payloadBundleName = payloadURL.deletingLastPathComponent().lastPathComponent
        let dependencyNames = try fileManager
            .contentsOfDirectory(atPath: dependencyDirectoryURL.path)
            .filter { $0 != payloadBundleName }
        guard !dependencyNames.isEmpty else { return }

        try createDirectory(at: destinationURL)
        for dependencyName in dependencyNames {
            try fileManager.copyItem(
                at: dependencyDirectoryURL.appendingPathComponent(dependencyName),
                to: destinationURL.appendingPathComponent(dependencyName),
            )
        }
    }

    private func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755],
        )
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
