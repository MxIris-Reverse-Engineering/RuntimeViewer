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

        /// Resident budget for the corpora of one engine, in megabytes: the
        /// corpora searched most recently stay in memory up to it. Past it, a
        /// corpus the engine's derived data holds stays on disk and is read
        /// back when a search needs it; any other is dropped whole and
        /// rebuilt when next asked for. AppKit and SwiftUI together are about
        /// 60 MB in memory. 256 until proposal
        /// `on-demand-corpora-and-cross-references`; see
        /// `residentLimitDefaultsRevision`.
        @Default(64)
        public var residentByteLimitMegabytes: Int

        /// How many images Call Hierarchy and Type References — in the Find
        /// navigator and the Inspector's References tab — scan at the same
        /// time, in the process that serves the engine (Settings UI clamps to
        /// 1...processorCount). Each keeps a core busy decoding an image's
        /// code; only indexed images are scanned.
        @Default(4)
        public var maximumConcurrentCrossReferenceScans: Int

        /// Keep Cross References Ready: whether the engine's process reads the
        /// cross references of every indexed image ahead of the queries, which
        /// then answer from what it read instead of scanning. Off drops what it
        /// read, and queries scan again.
        @Default(true)
        public var isCrossReferencePreparationEnabled: Bool

        /// Resident budget for prepared cross references, in megabytes. Keep
        /// Cross References Ready prepares indexed images, the Always Index
        /// ones first, until it is full; past it a query prepares the image
        /// it needs, and the images queried least recently are dropped. AppKit's
        /// take about 35 MB: 21 for its references, 14 for the names its
        /// results are shown with. 256 until proposal
        /// `on-demand-corpora-and-cross-references`.
        @Default(64)
        public var crossReferenceResidentByteLimitMegabytes: Int

        /// Which change of the two resident limits' defaults this file has
        /// been brought to. 0 for a file written before the defaults went from
        /// 256 to 64 MB, whose limits still at 256 were never changed by the
        /// user; `SettingsAccess.load()` moves those to 64 once and records
        /// `currentResidentLimitDefaultsRevision`, so a limit set to 256 later
        /// stays.
        @Default(0)
        public var residentLimitDefaultsRevision: Int

        public static let currentResidentLimitDefaultsRevision = 1

        /// What both resident limits defaulted to before revision 1.
        public static let legacyResidentLimitMegabytes = 256

        public static let `default` = Self()

        public var residentByteLimit: Int {
            max(0, residentByteLimitMegabytes) * 1024 * 1024
        }

        public var crossReferenceResidentByteLimit: Int {
            max(0, crossReferenceResidentByteLimitMegabytes) * 1024 * 1024
        }

        /// What a cross-reference query sends as its prepared index byte limit:
        /// the resident budget while Keep Cross References Ready is on, and
        /// none — scan instead — while it is off.
        public var preparedCrossReferenceByteLimit: Int? {
            isCrossReferencePreparationEnabled ? crossReferenceResidentByteLimit : nil
        }
    }
}
