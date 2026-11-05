#if os(macOS) || targetEnvironment(macCatalyst)

import AppKit
import LaunchServicesPrivate

extension LSBundleProxy {
    public var isSandbox: Bool {
        guard let entitlements = entitlements else { return false }
        guard let isSandbox = entitlements["com.apple.security.app-sandbox"] as? Bool else { return false }
        return isSandbox
    }
}

#endif
