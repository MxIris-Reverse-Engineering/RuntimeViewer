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
        /// Master switch. When off, no background indexing runs regardless of
        /// sub-mode toggles below.
        @Default(false)
        public var isEnabled: Bool

        /// Shared worker pool capacity used by both sub-modes (Settings UI
        /// clamps to 1...processorCount).
        @Default(4)
        public var maxConcurrency: Int

        /// Heuristic discovery: at document open / engine swap, BFS the main
        /// executable's dependency closure to `depth` levels and index every
        /// image found. Does NOT subscribe to dyld add-image notifications —
        /// images loaded after the initial sweep are not auto-indexed.
        @Codable
        @MemberInit
        public struct Heuristic {
            /// Whether heuristic main-executable BFS is enabled.
            @Default(true)
            public var isEnabled: Bool

            /// BFS depth from the main executable (Settings UI clamps to 1...5).
            @Default(1)
            public var depth: Int

            public static let `default` = Self()
        }

        @Default(Heuristic.default)
        public var heuristic: Heuristic

        /// One row in the user-configured "always-index" list. `identifier`
        /// is either a full imagePath (leading `/`) matched verbatim against
        /// the engine's `imageList`, or an imageName matched against the
        /// last path component of any loaded image. Entries that don't
        /// resolve to a loaded image are silently skipped (no-op, not
        /// marked failed).
        ///
        /// `followDependencies` opts the entry into the BFS dependency
        /// expansion that main-executable batches use; when false (the
        /// default) the batch is constrained to the resolved image alone,
        /// so adding "SwiftUICore" indexes SwiftUICore literally rather
        /// than every framework it links against.
        ///
        /// Declared before `Custom` so MetaCodable's `@Codable` macro can
        /// resolve the type when expanding `Custom`'s synthesized codable
        /// implementation; macro-generated code does not see types declared
        /// further down the same scope.
        @Codable
        @MemberInit
        public struct AlwaysIndexEntry: Equatable {
            @Default("")
            public var identifier: String

            @Default(false)
            public var followDependencies: Bool

            public static let `default` = Self()
        }

        /// Custom always-index list: user-maintained images that get indexed
        /// whenever a document opens, the engine changes, the entry list
        /// changes, or a fullReload fires.
        @Codable
        @MemberInit
        public struct Custom {
            /// Whether the custom always-index list is honored.
            @Default(true)
            public var isEnabled: Bool

            /// Fully qualified path is required so MetaCodable's `@Codable`
            /// macro can resolve the type from its generated source file
            /// (the synthesized init lives in a separate compilation unit
            /// that does not have `Settings.Indexing` as an enclosing scope).
            @Default([])
            public var entries: [Settings.Indexing.AlwaysIndexEntry]

            public static let `default` = Self()
        }

        @Default(Custom.default)
        public var custom: Custom

        public static let `default` = Self()
    }
}
