import Foundation
import SwiftMobileGestalt

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

#if os(watchOS)
import WatchKit
#endif

public enum DeviceIdentifier {
    /// Returns the device's UniqueDeviceID (UDID) from MobileGestalt.
    /// Falls back to identifierForVendor (iOS) or a generated UUID stored in UserDefaults.
    public static var uniqueDeviceID: String {
        if let udid = SMGCopyAnswerAsString(.identifying(.uniqueDeviceID)), !udid.isEmpty {
            return udid
        }

        #if canImport(UIKit) && !os(watchOS)
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            return vendorID
        }
        #endif

        return fallbackDeviceID
    }

    private static let fallbackDeviceIDKey = "com.RuntimeViewer.fallbackDeviceID"

    private static var fallbackDeviceID: String {
        if let existing = UserDefaults.standard.string(forKey: fallbackDeviceIDKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: fallbackDeviceIDKey)
        return id
    }
}
