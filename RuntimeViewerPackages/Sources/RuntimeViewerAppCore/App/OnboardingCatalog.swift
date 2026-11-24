#if os(macOS)

import Foundation

/// Every onboarding page the app has: the welcome page, and What's New by feature release.
///
/// **A feature release's version bump comes with its What's New.** `OnboardingCatalogTests` reads
/// `MARKETING_VERSION` from `Configurations/Version.xcconfig` and fails while the catalog has no page for
/// its feature release. The pages are written by hand from the release's changelogs (`Changelogs/`),
/// whose entries are whole sentences: a row here is a short title, one sentence and a symbol.
public struct OnboardingCatalog: Sendable {
    public var welcomePage: OnboardingPage
    /// What's New, by feature release. A release without an entry shows none.
    public var whatsNewPages: [FeatureRelease: OnboardingPage]

    public init(welcomePage: OnboardingPage, whatsNewPages: [FeatureRelease: OnboardingPage]) {
        self.welcomePage = welcomePage
        self.whatsNewPages = whatsNewPages
    }

    /// The page Help › What's New in RuntimeViewer shows: the release's own, or else the latest one
    /// before it. `nil` when there is none up to the release.
    public func latestWhatsNewPage(upTo release: FeatureRelease) -> OnboardingPage? {
        whatsNewPages
            .filter { $0.key <= release }
            .max { $0.key < $1.key }?
            .value
    }
}

extension OnboardingCatalog {
    /// RuntimeViewer's pages.
    public static let runtimeViewer = OnboardingCatalog(
        welcomePage: OnboardingPage(
            kind: .welcome,
            title: "Welcome to RuntimeViewer",
            bodyText: "Read the Objective-C, Swift and C++ interfaces of the images on your Mac, in other processes and on your devices.",
            image: .appIcon,
            features: [
                .init("Every Interface", description: "Browse the Objective-C, Swift and C++ objects of any image, printed with Xcode’s syntax highlighting.", symbol: .squareStack3dUp),
                .init("Jump Through Types", description: "Click a type in an interface to open it, and go back the way you came.", symbol: .arrowRightCircle),
                .init("Beyond This Process", description: "Attach to a running app, a Mac Catalyst app, the Simulator or a device, or open files from disk.", symbol: .appConnectedToAppBelowFill),
                .init("Find and Cross References", description: "Search every indexed interface and follow callers, callees and type references.", symbol: .magnifyingglass),
                .init("Made for Agents", description: "An MCP server and runtime-viewer-cli give coding agents the same interfaces.", symbol: .terminal),
            ]
        ),
        whatsNewPages: [
            FeatureRelease(major: 3, minor: 0): OnboardingPage(
                kind: .whatsNew(FeatureRelease(major: 3, minor: 0)),
                title: "What’s New in RuntimeViewer 3.0",
                features: [
                    .init("Find Navigator", description: "Search the interfaces of every indexed image, find types with their hierarchy, and find members.", symbol: .magnifyingglass),
                    .init("Cross References", description: "See who calls a method, what it calls and which functions use a type.", symbol: .arrowTriangleBranch),
                    .init("Files from Disk", description: "Open Mach-O files, bundles, folders and dyld shared caches, each in its own window.", symbol: .folder),
                    .init("C++ Interfaces", description: "Classes and namespaces recovered from RTTI, vtables and symbols, printed and exported as headers.", symbol: .curlybraces),
                    .init("Editor Panes", description: "Split the content area; each pane has its own tabs, history and jump bar.", symbol: .rectangleSplit2x1),
                    .init("Command-Line Tool", description: "runtime-viewer-cli ships inside the app and works without it running.", symbol: .terminal),
                ]
            ),
        ]
    )
}

#endif
