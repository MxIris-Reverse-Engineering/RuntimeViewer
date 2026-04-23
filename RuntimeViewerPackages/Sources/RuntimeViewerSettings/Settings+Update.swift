import Foundation
import MetaCodable

extension Settings {
    @Codable
    @MemberInit
    public struct Update {
        @Default(true)
        public var automaticallyChecks: Bool

        @Default(false)
        public var automaticallyDownloads: Bool

        @Default(Settings.CheckInterval.daily)
        public var checkInterval: Settings.CheckInterval

        @Default(false)
        public var includePrereleases: Bool

        public static let `default` = Self()

        /// Maps to `SPUUpdater.setAllowedChannels(_:)` and
        /// `SPUUpdaterDelegate.allowedChannels(for:)`.
        ///
        /// Sparkle semantics: entries without a `<sparkle:channel>` tag are
        /// the "default channel" and are always visible. An empty set means
        /// "default channel only"; `["beta"]` means "default + beta".
        public var allowedChannels: Set<String> {
            includePrereleases ? ["beta"] : []
        }
    }

    public enum CheckInterval: String, Codable, CaseIterable {
        case hourly
        case daily
        case weekly

        public var timeInterval: TimeInterval {
            switch self {
            case .hourly: 3_600
            case .daily: 86_400
            case .weekly: 604_800
            }
        }

        public var displayName: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
    }
}
