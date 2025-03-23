#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit

enum RuntimeViewerCatalystHelperLauncher {
    static let appName = "RuntimeViewerCatalystHelper"
    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents").appendingPathComponent("Applications").appendingPathComponent("\(appName).app")
}

#endif
