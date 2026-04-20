#if os(macOS)

import Foundation

/// Fetches the version of the running helper service daemon.
///
/// The app sends this request on launch to compare the service's compiled-in version
/// against the app's version. A mismatch indicates the service binary is outdated
/// and needs reinstallation.
public struct FetchServiceVersionRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchServiceVersion"

    public struct Response: RuntimeResponse, Codable {
        public let version: String

        public init(version: String) {
            self.version = version
        }
    }

    public init() {}
}

#endif
