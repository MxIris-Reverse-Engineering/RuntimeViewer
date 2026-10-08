public import Foundation

/// Finds the icon of the application a process belongs to by reading the
/// bundle, and hands back the file's bytes untouched.
///
/// No private API, which is the whole design constraint. The system's own
/// rounded, uniformly sized icons come from `LSApplicationProxy` and friends;
/// reaching them means verifying a private interface against the device's dyld
/// cache and then testing on the device. What is here instead is plain file
/// reading — `Info.plist` says which base name the icon has, and the file sits
/// in the bundle root — which costs the rounded mask and nothing else.
///
/// Cross-platform for the same reason ``RuntimeDeviceProcessEnumerator`` is:
/// only the iOS variant ships it, but every branch is file reading, so a Mac
/// test suite covers all of it. A device has neither a test runner nor a way to
/// fail a build.
///
/// **This type serves requests that arrived over a network.** The path comes
/// from the host, so ``validatedApplicationBundleURL(forPath:)`` and
/// ``readIconFile(named:inApplicationBundleAt:)`` are what stop it being an
/// arbitrary file read; read both before changing either.
public enum RuntimeDeviceApplicationIconLocator {
    // MARK: - Finding the bundle

    /// The application bundle an executable belongs to, if any.
    ///
    /// The nearest `.app` ancestor — which is also what makes an app extension
    /// resolve to its *host* application. An extension's executable sits in
    /// `Host.app/PlugIns/Extension.appex/`, and `.appex` does not end in
    /// `.app`, so the walk carries on up to the one bundle that has an icon of
    /// its own.
    ///
    /// `nil` for anything not inside a bundle, which is nearly every process on
    /// a device. That is both the common answer and the cheap one: no file is
    /// opened to reach it.
    public static func applicationBundlePath(forExecutableAtPath executablePath: String) -> String? {
        var components = (executablePath as NSString).pathComponents
        // The executable is never itself the bundle, so the first component
        // dropped is it — which also discards the lone "/" that a trailing
        // slash contributes as a component of its own.
        while components.count > 1 {
            components.removeLast()
            guard let lastComponent = components.last else { return nil }
            if isApplicationBundleName(lastComponent) {
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }

    // MARK: - Reading the icon

    /// The icon bytes for several bundles at once, keyed by the path as the
    /// caller spelled it.
    ///
    /// Keyed by the *given* string rather than a normalized one, because the
    /// caller matches these back against the ``RuntimeProcess/applicationBundlePath``
    /// of its processes and a key it did not ask for matches nothing. A bundle
    /// with no icon is absent rather than present and empty, so "no icon" and
    /// "an empty file" stay apart.
    public static func iconData(
        forApplicationBundlesAtPaths applicationBundlePaths: some Sequence<String>,
    ) -> [String: Data] {
        var iconDataByApplicationBundlePath: [String: Data] = [:]
        // Deduplicated here as well as by the caller: the caller is a different
        // build, and reading one bundle's icon twice is pure waste either way.
        for applicationBundlePath in Set(applicationBundlePaths) {
            guard let iconData = iconData(forApplicationBundleAtPath: applicationBundlePath) else { continue }
            iconDataByApplicationBundlePath[applicationBundlePath] = iconData
        }
        return iconDataByApplicationBundlePath
    }

    /// One bundle's icon, as the bytes that are in the file.
    ///
    /// Deliberately neither decoded nor re-encoded. The file is already a PNG
    /// and a PNG is what the host wants, so decoding here would cost a device's
    /// CPU to produce a lossy copy of what it was handed.
    public static func iconData(forApplicationBundleAtPath applicationBundlePath: String) -> Data? {
        guard let applicationBundleURL = validatedApplicationBundleURL(forPath: applicationBundlePath),
              let declaredBaseNames = declaredIconBaseNames(inApplicationBundleAt: applicationBundleURL)
        else { return nil }

        // Every declared base name is tried, not just the first. The names
        // under one key are sizes of the same artwork, so which one answers
        // does not matter — but a name whose file is missing is a real case,
        // and falling through to the next costs a `stat`.
        for baseName in declaredBaseNames {
            for suffix in iconFileNameSuffixes {
                if let iconData = readIconFile(named: baseName + suffix, inApplicationBundleAt: applicationBundleURL) {
                    return iconData
                }
            }
        }
        return nil
    }

    // MARK: - The bundle's own declaration

    /// The icon base names a bundle declares, in the order to try them.
    ///
    /// Returns `nil` rather than an empty array when nothing is declared, so
    /// "this bundle has no icon" is one answer rather than two.
    private static func declaredIconBaseNames(inApplicationBundleAt applicationBundleURL: URL) -> [String]? {
        let informationPropertyListURL = applicationBundleURL.appendingPathComponent(informationPropertyListFileName)
        guard let informationPropertyListData = try? Data(contentsOf: informationPropertyListURL),
              let decoded = try? PropertyListSerialization.propertyList(from: informationPropertyListData, format: nil),
              let informationPropertyList = decoded as? [String: Any]
        else { return nil }

        for declarationKey in iconDeclarationKeys {
            guard let iconDeclaration = informationPropertyList[declarationKey] as? [String: Any],
                  let primaryIcon = iconDeclaration[primaryIconKey] as? [String: Any],
                  let declaredBaseNames = primaryIcon[iconFilesKey] as? [String]
            else { continue }
            let usableBaseNames = declaredBaseNames.filter(isUsableIconBaseName)
            guard !usableBaseNames.isEmpty else { continue }
            return usableBaseNames
        }
        return nil
    }

    // MARK: - What a caller-supplied path is allowed to be

    /// The one place a path from the host becomes a file system location.
    ///
    /// Three refusals, each closing a different hole:
    ///
    /// - **Absolute only**, so a request cannot be resolved against whatever
    ///   directory the hosting process happens to be in.
    /// - **No `..` component**, *rejected* rather than resolved — resolving
    ///   would let `/Applications/Foo.app/../../elsewhere.app` name a directory
    ///   the caller was never offered.
    /// - **Must end in a real `.app` component**, which is what confines
    ///   reading to application bundles rather than to the file system.
    /// - **And that component must be a directory, not a symbolic link to
    ///   one.** The three tests above are all properties of a *string* from a
    ///   peer, and the reads that follow are not: the kernel resolves every
    ///   directory component of a path, so a `.app` that is a link would read
    ///   an `Info.plist` outside any bundle and then whatever that plist
    ///   declares. The no-follow attribute read in
    ///   ``readIconFile(named:inApplicationBundleAt:)`` covers the leaf only.
    ///
    /// Together with ``readIconFile(named:inApplicationBundleAt:)``, which only
    /// ever opens a name the bundle's own `Info.plist` declared, this is what
    /// keeps the command from being an arbitrary file read primitive.
    private static func validatedApplicationBundleURL(forPath applicationBundlePath: String) -> URL? {
        guard applicationBundlePath.hasPrefix("/") else { return nil }
        guard !(applicationBundlePath as NSString).pathComponents.contains(parentDirectoryComponent) else { return nil }
        // `lastPathComponent` rather than the last of `pathComponents`: a
        // trailing slash arrives as a final "/" component of its own — measured
        // — and would fail the extension check for a path that is valid.
        guard isApplicationBundleName((applicationBundlePath as NSString).lastPathComponent) else { return nil }
        // `attributesOfItem` does not follow a link, so a linked `.app` reports
        // as `.typeSymbolicLink` here rather than as the directory it points at.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: applicationBundlePath),
              attributes[.type] as? FileAttributeType == .typeDirectory
        else { return nil }
        return URL(fileURLWithPath: applicationBundlePath, isDirectory: true)
    }

    /// Whether a single path component names an application bundle.
    ///
    /// The length test is not redundant: a component of exactly `.app` is a
    /// hidden directory, not a bundle, and it satisfies the suffix on its own.
    private static func isApplicationBundleName(_ pathComponent: String) -> Bool {
        pathComponent.hasSuffix(applicationBundlePathExtension)
            && pathComponent.count > applicationBundlePathExtension.count
    }

    /// Whether a name out of `Info.plist` may be appended to the bundle's path.
    ///
    /// A path separator or a leading dot would let a declared name walk out of
    /// the bundle the request named. That the plist belongs to the bundle does
    /// not make this unnecessary — the bundle is chosen by the caller, so a
    /// hostile one is a hostile one the caller picked.
    private static func isUsableIconBaseName(_ baseName: String) -> Bool {
        !baseName.isEmpty
            && !baseName.hasPrefix(".")
            && !baseName.contains("/")
    }

    // MARK: - The file itself

    /// One candidate icon file, or `nil` for every reason it is not one.
    ///
    /// Sized before being read, so an oversized file costs a `stat` instead of
    /// its own length in memory. The regular-file test is load-bearing beyond
    /// tidiness: file attributes are read without following symbolic links, so
    /// a link planted under an icon's name reports as a link here and is
    /// refused rather than followed out of the bundle.
    private static func readIconFile(named fileName: String, inApplicationBundleAt applicationBundleURL: URL) -> Data? {
        let fileURL = applicationBundleURL.appendingPathComponent(fileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = attributes[.size] as? Int,
              byteCount > 0,
              byteCount <= maximumIconByteCount,
              let iconData = try? Data(contentsOf: fileURL),
              iconData.starts(with: pngSignature)
        else { return nil }
        return iconData
    }

    // MARK: - Constants

    private static let applicationBundlePathExtension = ".app"

    private static let informationPropertyListFileName = "Info.plist"

    private static let parentDirectoryComponent = ".."

    private static let primaryIconKey = "CFBundlePrimaryIcon"

    private static let iconFilesKey = "CFBundleIconFiles"

    /// Where to look for the declared base name, in preference order.
    ///
    /// The general key first and the iPad override second, which is the
    /// opposite of what the key names suggest. Measured on the iOS 27 system
    /// applications: all 56 that declare an icon declare it under
    /// `CFBundleIcons`, so the general key alone resolves every one of them,
    /// while preferring the override would hand an iPhone the iPad artwork. The
    /// override stays as the fallback for an iPad-only application, which the
    /// measurement did not contain but which the key exists for.
    private static let iconDeclarationKeys = ["CFBundleIcons", "CFBundleIcons~ipad"]

    /// What to append to a declared base name, best first.
    ///
    /// A declared name is a *base* name: `Info.plist` says `AppIcon60x60` and
    /// the file beside it is `AppIcon60x60@2x.png`. Ordered by how much detail
    /// the file carries, because the host scales an icon down and never up.
    ///
    /// Measured: this list resolves 55 of the 56 iOS 27 system applications
    /// that declare an icon. The one it does not is `GameCenterUIService.app`,
    /// whose icon exists only inside a compiled `Assets.car` and so is out of
    /// reach of any route that reads files.
    private static let iconFileNameSuffixes = [
        "@3x.png",
        "@2x.png",
        ".png",
        "@2x~ipad.png",
        "~ipad.png",
    ]

    /// A PNG's first eight bytes.
    ///
    /// Checked because the bytes are forwarded verbatim and decoded at the far
    /// end: a non-PNG file under an icon's name would otherwise travel the
    /// whole way to produce nothing, where falling through to the next
    /// candidate here may well produce the icon.
    ///
    /// It passes the Xcode-crushed form that every shipped application icon is
    /// in. Those carry a `CgBI` chunk immediately after this signature and are
    /// unreadable to a standard PNG decoder — measured on this project's own
    /// `.ipa`, and measured also that macOS's ImageIO reads them correctly,
    /// colours included. That second measurement is what makes forwarding the
    /// file verbatim viable at all; without it this would have to decode and
    /// re-encode on the device.
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The largest icon file worth sending.
    ///
    /// An application icon is tens of kilobytes, so this rejects nothing real.
    /// It exists because the path being read came over the network: without it,
    /// a bundle holding something large under an icon's name would be read into
    /// memory and sent, once per bundle named in one request.
    private static let maximumIconByteCount = 2 * 1024 * 1024
}
