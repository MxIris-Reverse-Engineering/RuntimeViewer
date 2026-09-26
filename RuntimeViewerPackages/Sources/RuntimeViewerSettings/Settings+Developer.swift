import Foundation
import MetaCodable

extension Settings {
    /// Switches for exercising the app itself while developing it.
    ///
    /// Settings › Developer edits them, and that page exists in Debug builds only. They are
    /// persisted like every other setting, and ``isEnabled`` governs all of them at once: while it
    /// is off, no option takes effect, yet each keeps its configured value for the next time it
    /// is turned on. Consumers read the `effective…` properties, which already account for the
    /// switch, rather than checking it themselves.
    @Codable
    @MemberInit
    public struct Developer: Sendable {
        /// The master switch.
        @Default(false)
        public var isEnabled: Bool

        /// How long every interface fetch of the content pane waits before it starts, in seconds,
        /// while ``isEnabled`` is on. Zero turns it off.
        ///
        /// The wait comes ahead of the document's interface cache, so it holds back an object
        /// that is already cached too. That is the point: it brings the content loading plate
        /// up on demand, for any delay longer than its 100-millisecond grace period.
        @Default(0.0)
        public var contentLoadingDelay: TimeInterval

        public static let `default` = Self()

        /// The content loading delay that actually applies: ``contentLoadingDelay`` while the
        /// master switch is on, zero otherwise.
        public var effectiveContentLoadingDelay: TimeInterval {
            isEnabled ? contentLoadingDelay : 0
        }
    }
}
