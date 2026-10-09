import Foundation
import MetaCodable

extension Settings {
    /// The Find navigator's corpus: whether interfaces are kept searchable at
    /// all, and how much of them may stay resident.
    ///
    /// The corpus is the text of every indexed image's interfaces, printed
    /// once per image in the engine's process (proposal `0029-find-navigator`
    /// §1). Text and member searches read it; the relationship modes do not
    /// need it and keep working with it off.
    @Codable
    @MemberInit
    public struct Search: Sendable {
        /// Master switch. Off drops every corpus and builds none; text and
        /// member searches then report every indexed image as unbuilt.
        @Default(true)
        public var isCorpusEnabled: Bool

        /// Resident budget for the corpora of one engine, in megabytes. Past
        /// it, the images searched least recently are dropped whole and
        /// rebuilt when next asked for. AppKit and SwiftUI together are about
        /// 60 MB; 256 MB holds roughly eight frameworks of SwiftUI's size.
        @Default(256)
        public var residentByteLimitMegabytes: Int

        public static let `default` = Self()

        public var residentByteLimit: Int {
            max(0, residentByteLimitMegabytes) * 1024 * 1024
        }
    }
}
