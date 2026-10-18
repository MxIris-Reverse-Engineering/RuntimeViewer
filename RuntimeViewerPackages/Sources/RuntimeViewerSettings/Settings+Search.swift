import Foundation
import MetaCodable

extension Settings {
    /// The Find navigator's corpus — whether interfaces are kept searchable at
    /// all, and how much of them may stay resident — and how many images its
    /// cross-reference modes scan at once.
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

        /// How many images Call Hierarchy and Type References — in the Find
        /// navigator and the Inspector's References tab — scan at the same
        /// time, in the process that serves the engine (Settings UI clamps to
        /// 1...processorCount). Each keeps a core busy decoding an image's
        /// code; only indexed images are scanned.
        @Default(4)
        public var maximumConcurrentCrossReferenceScans: Int

        public static let `default` = Self()

        public var residentByteLimit: Int {
            max(0, residentByteLimitMegabytes) * 1024 * 1024
        }
    }
}
