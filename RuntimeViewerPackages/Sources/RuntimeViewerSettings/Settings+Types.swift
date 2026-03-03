import Foundation
import RuntimeViewerCore
import MetaCodable

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

    @Codable
    @MemberInit
    public struct General {
        @Default(Settings.Appearances.system)
        public var appearance: Settings.Appearances
        
        public static let `default` = Self()
    }

    @Codable
    @MemberInit
    public struct Notifications {
        /// Whether notifications are enabled globally
        @Default(true)
        public var isEnabled: Bool

        /// Whether to show notification when connected to a runtime engine
        @Default(true)
        public var showOnConnect: Bool

        /// Whether to show notification when disconnected from a runtime engine
        @Default(true)
        public var showOnDisconnect: Bool
        
        public static let `default` = Self()
    }

    public typealias TransformerSettings = RuntimeViewerCore.Transformer.Configuration

    @Codable
    @MemberInit
    public struct MCP {
        /// Whether the MCP server is enabled
        @Default(true)
        public var isEnabled: Bool

        /// Whether to use a fixed port instead of automatic assignment
        @Default(false)
        public var useFixedPort: Bool

        /// The fixed port number to use when useFixedPort is true
        @Default(9277)
        public var fixedPort: UInt16
        
        public static let `default` = Self()
    }
}
