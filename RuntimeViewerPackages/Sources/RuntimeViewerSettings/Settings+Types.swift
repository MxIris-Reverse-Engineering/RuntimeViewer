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

        /// Caps the recursion of `expandItem(_:expandChildren: true)` on
        /// double-click. Without a cap, double-clicking a root with a deep
        /// subtree (e.g. the dyld shared cache) freezes the main thread while
        /// AppKit walks every descendant.
        @Default(3)
        public var sidebarMaxExpansionDepth: Int

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

        /// The port file name used by both the MCP HTTP server and the settings UI.
        public static let portFileName = "mcp-http-port"
    }

    @Codable
    @MemberInit
    public struct Indexing {
        @Codable
        @MemberInit
        public struct BackgroundMode {
            /// Whether background indexing is enabled
            @Default(false)
            public var isEnabled: Bool

            /// Indexing depth (valid range enforced by the Settings UI: 1...5)
            @Default(1)
            public var depth: Int

            /// Maximum concurrent indexing tasks (Settings UI clamps to 1...processorCount)
            @Default(4)
            public var maxConcurrency: Int

            public static let `default` = Self()
        }

        @Default(BackgroundMode.default)
        public var backgroundMode: BackgroundMode

        /// User-configured "always-index" list. Each entry is either a full
        /// imagePath (leading `/`) matched verbatim against the engine's
        /// `imageList`, or an imageName matched against the last path
        /// component of any loaded image. Entries that don't resolve to a
        /// loaded image are silently skipped (no-op, not marked failed).
        ///
        /// Lives at `Indexing` scope rather than inside `BackgroundMode` so
        /// users can edit it even when background indexing is disabled.
        @Default([])
        public var alwaysIndexIdentifiers: [String]

        public static let `default` = Self()
    }
}
