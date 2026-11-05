#if os(macOS)

import AppKit
import LaunchServicesPrivate

extension NSRunningApplication {
    public var applicationProxy: LSApplicationProxy? {
        guard let bundleIdentifier else { return nil }
        return LSApplicationProxy(forIdentifier: bundleIdentifier)
    }

    public var isSandbox: Bool {
        applicationProxy?.isSandbox ?? false
    }
}

#endif
