import Testing
import Foundation
@testable import RuntimeViewerDeviceInjection

/// Where a process's icon comes from, and — just as much of the point — what a
/// bundle path arriving over the network is allowed to reach.
///
/// Every one of these runs on a Mac against a bundle built in a temporary
/// directory, which is the reason the locator is cross-platform at all. The
/// device has no test runner and no way to fail a build, so an iOS-only
/// implementation would have no test.
@Suite("Device application icon locator")
struct RuntimeDeviceApplicationIconLocatorTests {
    // MARK: - Finding the bundle an executable belongs to

    @Test("An application's executable resolves to its own bundle")
    func executableResolvesToItsApplication() {
        #expect(
            RuntimeDeviceApplicationIconLocator
                .applicationBundlePath(forExecutableAtPath: "/Applications/MobileSafari.app/MobileSafari")
                == "/Applications/MobileSafari.app"
        )
    }

    /// The case the whole walk exists for. An extension's executable lives in
    /// `Host.app/PlugIns/Extension.appex/`, and the `.appex` has no icon of its
    /// own, so stopping at the nearest bundle-looking directory would leave
    /// every extension blank.
    @Test("An app extension resolves to its host application, not to its own .appex")
    func appExtensionResolvesToItsHostApplication() {
        #expect(
            RuntimeDeviceApplicationIconLocator
                .applicationBundlePath(
                    forExecutableAtPath: "/var/containers/Bundle/Application/ABC/Thing.app/PlugIns/ThingWidget.appex/ThingWidget",
                )
                == "/var/containers/Bundle/Application/ABC/Thing.app"
        )
    }

    @Test("The nearest enclosing application wins")
    func nearestApplicationWins() {
        #expect(
            RuntimeDeviceApplicationIconLocator
                .applicationBundlePath(forExecutableAtPath: "/Applications/Outer.app/Helpers/Inner.app/Inner")
                == "/Applications/Outer.app/Helpers/Inner.app"
        )
    }

    /// Nearly every process on a device lands here, so this is the common
    /// answer rather than the edge case — and it has to cost nothing, which is
    /// why it is a walk over the string and opens no file.
    @Test("An executable in no bundle resolves to no bundle", arguments: [
        "/usr/libexec/backboardd",
        "/sbin/launchd",
        "/usr/sbin/mediaserverd",
        "/",
        "launchd",
        "",
    ])
    func executableOutsideAnyBundleResolvesToNothing(_ executablePath: String) {
        #expect(RuntimeDeviceApplicationIconLocator.applicationBundlePath(forExecutableAtPath: executablePath) == nil)
    }

    /// A component of exactly `.app` is a hidden directory, and it satisfies
    /// the suffix test on its own — so the length test next to that suffix is
    /// load-bearing, not decoration.
    @Test("A hidden directory named only for the extension is not a bundle")
    func hiddenDirectoryNamedLikeTheExtensionIsNotABundle() {
        #expect(
            RuntimeDeviceApplicationIconLocator
                .applicationBundlePath(forExecutableAtPath: "/var/mobile/.app/payload") == nil
        )
    }

    // MARK: - Reading the icon

    /// The trap this whole `Info.plist` read exists to avoid. Measured on iOS
    /// 27: Safari declares `AppIconUpdated60x60` and Settings declares
    /// `Settings60x60`, so assuming `AppIcon` would miss most of the system
    /// applications. The decoy file is what makes this test say so — a locator
    /// that guessed would find it and pass everything else.
    @Test("The base name is read from Info.plist, which is not always AppIcon")
    func baseNameIsReadRatherThanAssumed() throws {
        let declared = pngBytes(filler: 0x11)
        try withApplicationBundle(
            named: "MobileSafari.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIconUpdated60x60"]),
            files: [
                "AppIconUpdated60x60@2x.png": declared,
                "AppIcon@2x.png": pngBytes(filler: 0x22),
            ],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == declared
            )
        }
    }

    /// The host scales down and never up, so the most detailed file present is
    /// the one worth sending.
    @Test("@3x is preferred over @2x and over the unsuffixed file")
    func mostDetailedCandidateWins() throws {
        let tripleScale = pngBytes(filler: 0x33)
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [
                "AppIcon60x60.png": pngBytes(filler: 0x01),
                "AppIcon60x60@2x.png": pngBytes(filler: 0x02),
                "AppIcon60x60@3x.png": tripleScale,
            ],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == tripleScale
            )
        }
    }

    @Test("A bundle shipping only one of the candidates still answers", arguments: [
        "AppIcon60x60@2x.png",
        "AppIcon60x60.png",
        "AppIcon60x60@2x~ipad.png",
        "AppIcon60x60~ipad.png",
    ])
    func anySingleCandidateAnswers(_ fileName: String) throws {
        let onlyFile = pngBytes(filler: 0x44)
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [fileName: onlyFile],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == onlyFile
            )
        }
    }

    /// A declared name whose file is not there is a real case — measured, one
    /// of the 56 iOS 27 applications that declare an icon keeps it only inside
    /// a compiled asset catalogue. Falling through to the next declared name
    /// costs a `stat` and is what keeps a bundle with one stale declaration
    /// from reading as iconless.
    @Test("A declared name with no file falls through to the next declared name")
    func missingFileFallsThroughToTheNextDeclaration() throws {
        let second = pngBytes(filler: 0x55)
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIconMissing", "AppIconPresent"]),
            files: ["AppIconPresent@2x.png": second],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == second
            )
        }
    }

    @Test("A bundle that declares an icon it does not ship has no icon")
    func declaredButEntirelyMissingHasNoIcon() throws {
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [:],
        ) { applicationBundleURL in
            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
        }
    }

    /// Most of a device's bundles. A `ViewService` ships no icon and declares
    /// none, and that is a state rather than a failure.
    @Test("A bundle with no icon declaration has no icon, even with a file that looks like one")
    func noDeclarationMeansNoIcon() throws {
        try withApplicationBundle(
            named: "SomeViewService.app",
            informationPropertyList: ["CFBundleIdentifier": "com.example.viewservice"],
            files: ["AppIcon60x60@2x.png": pngBytes()],
        ) { applicationBundleURL in
            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
        }
    }

    @Test("A directory named like a bundle but holding no Info.plist has no icon")
    func bundleWithoutInformationPropertyList() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let applicationBundleURL = rootURL.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationBundleURL, withIntermediateDirectories: true)
        #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
    }

    /// The general key is tried first and the iPad override second, which is
    /// the opposite of the key names' suggestion and was chosen from the
    /// measurement: all 56 of the iOS 27 applications that declare an icon
    /// declare it under `CFBundleIcons`. The override still has to answer for a
    /// bundle that declares only it, which is what this pins.
    @Test("The iPad override answers for a bundle that declares nothing else")
    func iPadOverrideIsTheFallback() throws {
        let overrideIcon = pngBytes(filler: 0x66)
        try withApplicationBundle(
            named: "PadOnly.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon76x76"], underKey: "CFBundleIcons~ipad"),
            files: ["AppIcon76x76@2x~ipad.png": overrideIcon],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == overrideIcon
            )
        }
    }

    @Test("The general key wins over the iPad override when both are declared")
    func generalKeyWinsOverTheIPadOverride() throws {
        let general = pngBytes(filler: 0x77)
        var informationPropertyList = iconDeclaration(baseNames: ["AppIcon60x60"])
        for (key, value) in iconDeclaration(baseNames: ["AppIcon76x76"], underKey: "CFBundleIcons~ipad") {
            informationPropertyList[key] = value
        }
        try withApplicationBundle(
            named: "Universal.app",
            informationPropertyList: informationPropertyList,
            files: [
                "AppIcon60x60@2x.png": general,
                "AppIcon76x76@2x~ipad.png": pngBytes(filler: 0x88),
            ],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == general
            )
        }
    }

    /// The bytes are forwarded without being decoded, so a file that is not a
    /// PNG would travel the whole way to produce nothing at the far end.
    /// Skipping it here lets a later candidate answer instead.
    @Test("A file under an icon's name that is not a PNG is skipped")
    func nonPNGCandidateIsSkipped() throws {
        let realIcon = pngBytes(filler: 0x99)
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [
                "AppIcon60x60@3x.png": Data("not a png at all".utf8),
                "AppIcon60x60@2x.png": realIcon,
            ],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == realIcon
            )
        }
    }

    /// An empty file passes no signature check, but it is worth its own case:
    /// returning empty `Data` would key the response and make the host render a
    /// blank row where it should render the generic icon.
    @Test("An empty file under an icon's name is skipped")
    func emptyCandidateIsSkipped() throws {
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: ["AppIcon60x60@2x.png": Data()],
        ) { applicationBundleURL in
            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
        }
    }

    /// The cap exists because the path came over the network: one bundle with
    /// something large under an icon's name would otherwise be read into memory
    /// and sent, once per bundle named in a request.
    @Test("A file past the size cap is skipped, and a smaller candidate answers instead")
    func oversizedCandidateIsSkipped() throws {
        let smallIcon = pngBytes(filler: 0xAA)
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [
                "AppIcon60x60@3x.png": pngBytes(filler: 0xBB, count: 3 * 1024 * 1024),
                "AppIcon60x60@2x.png": smallIcon,
            ],
        ) { applicationBundleURL in
            #expect(
                RuntimeDeviceApplicationIconLocator
                    .iconData(forApplicationBundleAtPath: applicationBundleURL.path) == smallIcon
            )
        }
    }

    // MARK: - What a path from the network may reach

    /// The first of the three refusals. Without it the command reads files
    /// rather than application bundles.
    @Test("A path that does not name an application bundle is refused", arguments: [
        "/etc/passwd",
        "/etc",
        "/Applications",
        "/Applications/Thing.appex",
        "/var/mobile/.app",
        "Relative.app",
        "",
    ])
    func pathsThatAreNotApplicationBundlesAreRefused(_ applicationBundlePath: String) {
        #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundlePath) == nil)
    }

    /// `..` is rejected rather than resolved, because resolving it would let a
    /// request name a directory it was never offered and still end in `.app`.
    /// The control assertion is what makes this test mean anything: the same
    /// bundle answers when it is named directly.
    @Test("A path containing .. is refused, even when it would resolve to a real bundle")
    func parentDirectoryTraversalIsRefused() throws {
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: ["AppIcon60x60@2x.png": pngBytes()],
        ) { applicationBundleURL in
            // The control: named directly, this bundle does answer.
            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) != nil)

            let viaParentDirectory = applicationBundleURL.deletingLastPathComponent().path + "/Elsewhere/../Thing.app"
            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: viaParentDirectory) == nil)
        }
    }

    /// The second half of the boundary: the caller names a bundle, never a
    /// file, so a declared name that is a path must not be followed. The plist
    /// belonging to the bundle does not make this unnecessary — the bundle is
    /// the caller's choice, so a hostile one is a hostile one the caller
    /// picked.
    @Test("A declared base name cannot reach outside the bundle", arguments: [
        "../outside",
        "../../outside",
        "/etc/outside",
        "..",
        ".hidden",
        "",
    ])
    func declaredBaseNameCannotEscapeTheBundle(_ declaredBaseName: String) throws {
        try withApplicationBundle(
            named: "Hostile.app",
            informationPropertyList: iconDeclaration(baseNames: [declaredBaseName]),
            files: [:],
        ) { applicationBundleURL in
            // Planted where "../outside" would land, as a real PNG of the size
            // the locator accepts — so the only thing refusing it is the name
            // filter.
            let outsideURL = applicationBundleURL.deletingLastPathComponent().appendingPathComponent("outside@2x.png")
            try pngBytes().write(to: outsideURL)

            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
        }
    }

    /// File attributes are read without following links, so a link planted
    /// under an icon's name reports as a link and is refused. Were it followed,
    /// a bundle the caller can write would be a way out of the bundle that the
    /// name filter above does not cover.
    @Test("A symbolic link under an icon's name is refused rather than followed")
    func symbolicLinkCandidateIsRefused() throws {
        try withApplicationBundle(
            named: "Thing.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: [:],
        ) { applicationBundleURL in
            let outsideURL = applicationBundleURL.deletingLastPathComponent().appendingPathComponent("outside.png")
            try pngBytes().write(to: outsideURL)
            try FileManager.default.createSymbolicLink(
                at: applicationBundleURL.appendingPathComponent("AppIcon60x60@2x.png"),
                withDestinationURL: outsideURL,
            )

            #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: applicationBundleURL.path) == nil)
        }
    }

    /// The link above is the *leaf*; this one is the `.app` itself, and the
    /// no-follow attribute read does not cover it — the kernel follows every
    /// directory component of a path before reaching the leaf, so a `.app` that
    /// is a link reads an `Info.plist` outside any real bundle and then
    /// whatever that plist declares.
    ///
    /// The path comes from the host over a connection with no authentication,
    /// so "ends in `.app`" is a string property of a caller-supplied value and
    /// not evidence about the directory it names. Reading what a bundle
    /// declares is confined to bundles only if the component really is one.
    @Test("A .app that is itself a symbolic link is refused rather than followed")
    func symbolicLinkApplicationBundleIsRefused() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        // Deliberately not named `.app`: somewhere the caller was never
        // offered, which is the point of planting the link.
        let elsewhereURL = rootURL.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhereURL, withIntermediateDirectories: true)
        let informationPropertyListData = try PropertyListSerialization.data(
            fromPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            format: .xml,
            options: 0,
        )
        try informationPropertyListData.write(to: elsewhereURL.appendingPathComponent("Info.plist"))
        try pngBytes().write(to: elsewhereURL.appendingPathComponent("AppIcon60x60@3x.png"))

        let linkURL = rootURL.appendingPathComponent("Link.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: elsewhereURL)

        #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundleAtPath: linkURL.path) == nil)
    }

    // MARK: - Several bundles at once

    /// Keyed by the path the caller asked for, because that is what the caller
    /// matches against its processes. A bundle with no icon is absent rather
    /// than present and empty, so the host can tell "no icon" from "an icon of
    /// no bytes" and show the generic one.
    @Test("A batch is keyed by the paths asked for, and iconless bundles are absent")
    func batchKeysByTheRequestedPath() throws {
        let icon = pngBytes(filler: 0xCC)
        try withApplicationBundle(
            named: "WithIcon.app",
            informationPropertyList: iconDeclaration(baseNames: ["AppIcon60x60"]),
            files: ["AppIcon60x60@2x.png": icon],
        ) { withIconURL in
            try withApplicationBundle(
                named: "WithoutIcon.app",
                informationPropertyList: ["CFBundleIdentifier": "com.example.plain"],
                files: [:],
            ) { withoutIconURL in
                let result = RuntimeDeviceApplicationIconLocator.iconData(
                    forApplicationBundlesAtPaths: [
                        withIconURL.path,
                        withoutIconURL.path,
                        // Asked for twice on purpose: a caller that did not
                        // deduplicate must not make this read the bundle twice
                        // or produce two keys.
                        withIconURL.path,
                        "/Applications/NotThere.app",
                    ],
                )
                #expect(result.count == 1)
                #expect(result[withIconURL.path] == icon)
                #expect(result[withoutIconURL.path] == nil)
            }
        }
    }

    @Test("Asking about nothing answers nothing")
    func emptyBatch() {
        #expect(RuntimeDeviceApplicationIconLocator.iconData(forApplicationBundlesAtPaths: [String]()).isEmpty)
    }
}

// MARK: - Fixtures

/// Bytes that satisfy the locator's signature check without being an image.
///
/// Enough of a PNG for what is under test: the locator forwards bytes and never
/// decodes them, so the signature is the whole of what it inspects. Using a
/// real image here would hide a locator that returned the wrong file, since
/// every real icon would decode.
private func pngBytes(filler: UInt8 = 0xAB, count: Int = 64) -> Data {
    Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: filler, count: count)
}

private func iconDeclaration(baseNames: [String], underKey key: String = "CFBundleIcons") -> [String: Any] {
    [key: ["CFBundlePrimaryIcon": ["CFBundleIconFiles": baseNames]]]
}

private func makeTemporaryDirectory() throws -> URL {
    let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("RuntimeDeviceApplicationIconLocatorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

/// Builds a throwaway application bundle, runs `body` against it, and removes
/// it afterwards.
///
/// Built rather than checked in: what is under test is which file names the
/// locator probes for, and a fixture committed as files would only ever be as
/// right as the code reading it.
@discardableResult
private func withApplicationBundle<Result>(
    named bundleName: String,
    informationPropertyList: [String: Any],
    files: [String: Data],
    body: (URL) throws -> Result,
) throws -> Result {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let applicationBundleURL = rootURL.appendingPathComponent(bundleName, isDirectory: true)
    try FileManager.default.createDirectory(at: applicationBundleURL, withIntermediateDirectories: true)
    let informationPropertyListData = try PropertyListSerialization.data(
        fromPropertyList: informationPropertyList,
        format: .xml,
        options: 0,
    )
    try informationPropertyListData.write(to: applicationBundleURL.appendingPathComponent("Info.plist"))
    for (fileName, contents) in files {
        try contents.write(to: applicationBundleURL.appendingPathComponent(fileName))
    }

    return try body(applicationBundleURL)
}
