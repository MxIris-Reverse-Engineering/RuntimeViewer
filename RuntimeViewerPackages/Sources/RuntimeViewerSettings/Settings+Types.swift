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

    public struct MCP: Codable {
        /// Whether the MCP server is enabled
        public var isEnabled: Bool = true

        /// Whether to use a fixed port instead of automatic assignment
        public var useFixedPort: Bool = false

        /// The fixed port number to use when useFixedPort is true
        public var fixedPort: UInt16 = 9277
    }
}
