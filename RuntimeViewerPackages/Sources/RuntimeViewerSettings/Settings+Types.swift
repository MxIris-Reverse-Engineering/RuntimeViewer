import Foundation
import RuntimeViewerCore

extension Settings {
    /// The appearance of the app
    /// - **system**: uses the system appearance
    /// - **dark**: always uses dark appearance
    /// - **light**: always uses light appearance
    public enum Appearances: String, Codable {
        case system
        case light
        case dark
    }

    public struct General: Codable {
        public var appearance: Appearances = .system
    }

    public struct Notifications: Codable {
        /// Whether notifications are enabled globally
        public var isEnabled: Bool = true

        /// Whether to show notification when connected to a runtime engine
        public var showOnConnect: Bool = true

        /// Whether to show notification when disconnected from a runtime engine
        public var showOnDisconnect: Bool = true
    }

    public typealias TransformerSettings = RuntimeViewerCore.Transformer.Configuration
}
