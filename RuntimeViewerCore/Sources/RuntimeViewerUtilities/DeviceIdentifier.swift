import Foundation
import Security
import SwiftMobileGestalt

public enum DeviceIdentifier {
    /// Returns the device's UniqueDeviceID (UDID) from MobileGestalt.
    public static let uniqueDeviceID: String = {
        if let udid = SMGCopyAnswerAsString(.identifying(.uniqueDeviceID)), !udid.isEmpty {
            return udid
        }
        return fallbackDeviceID
    }()

    private static let fallbackService = "com.RuntimeViewer"
    private static let fallbackAccount = "fallbackDeviceID"

    private static let fallbackDeviceID: String = {
        if let existing = readFromKeychain() {
            return existing
        }
        let id = UUID().uuidString
        saveToKeychain(id)
        return id
    }()

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fallbackService,
            kSecAttrAccount as String: fallbackAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fallbackService,
            kSecAttrAccount as String: fallbackAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
