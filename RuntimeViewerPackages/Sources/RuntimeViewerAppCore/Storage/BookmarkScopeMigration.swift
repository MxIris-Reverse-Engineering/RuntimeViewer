import Foundation
import FoundationToolbox
import RuntimeViewerCommunication
import RuntimeViewerCore

/// The one-time move of the bookmark dictionaries off `RuntimeSource` keys and
/// onto ``RuntimeBookmarkScope`` keys.
///
/// Kept permanently, like the flat-array migration before it: a user who skips
/// several releases still arrives here, and the code costs nothing while it has
/// nothing to do.
///
/// Best-effort by design. What cannot be mapped is logged and left behind
/// rather than announced — the old file is never deleted, so anything dropped
/// is still recoverable, and a launch-time alert saying "some bookmarks did not
/// come across" gives the user nothing they can act on.
@Loggable(.private)
enum BookmarkScopeMigration {
    /// One old dictionary entry, in the order it appeared on disk.
    ///
    /// Order matters and a `Dictionary` cannot carry it. Neither can it carry
    /// the entries themselves: the old on-disk form is a key/value-alternating
    /// array whose keys encode a display name that `RuntimeSource.==` ignores,
    /// so decoding it *as* a dictionary drops every entry that collides with a
    /// later one — the third defect this work exists to remove, and one that
    /// would eat the data on the way into the migration if the migration read
    /// through a dictionary.
    struct Entry<Payload> {
        let source: RuntimeSource
        let payload: Payload
    }

    struct Outcome<Payload> {
        let migrated: [String: Payload]
        /// Sources that produced no scope at all, so their entries were dropped.
        let discardedSourceCount: Int
        /// Sources beyond the first that landed on a scope already taken, and
        /// were therefore merged into it.
        let mergedSourceCount: Int
    }

    // MARK: - Reading the old on-disk forms

    /// A bookmark from the oldest form, where every entry carried its own
    /// source and the file was one flat array.
    ///
    /// Declared here rather than reusing `RuntimeImageBookmark`, which no
    /// longer has a source to decode into — the whole point of dropping that
    /// field is that a bookmark stops naming its own peer. Reading the old file
    /// still needs to see it, and this is the only place that does.
    struct LegacyFlatImageBookmark: Decodable {
        let source: RuntimeSource
        let imageNode: RuntimeImageNode
    }

    /// The object-bookmark counterpart of ``LegacyFlatImageBookmark``.
    struct LegacyFlatObjectBookmark: Decodable {
        let source: RuntimeSource
        let object: RuntimeObject
    }

    /// Parses a flat array, skipping and logging entries that fail on their
    /// own. Returns `nil` when the file is missing or is not an array at all.
    static func flatEntries<Element: Decodable>(
        ofElement elementType: Element.Type,
        inArchiveAt url: URL
    ) -> [Element]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        } catch {
            #log(.error, "Bookmark migration: \(url.lastPathComponent, privacy: .public) could not be parsed, nothing migrated from it: \(error, privacy: .public)")
            return nil
        }
        guard let rawElements = jsonObject as? [Any] else {
            #log(.error, "Bookmark migration: \(url.lastPathComponent, privacy: .public) is not an array, nothing migrated from it")
            return nil
        }

        var elements: [Element] = []
        for (offset, rawElement) in rawElements.enumerated() {
            do {
                elements.append(try JSONDecoder.decodeFromJSONObject(Element.self, rawElement))
            } catch {
                #log(.error, "Bookmark migration: skipped element \(offset, privacy: .public) of \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        return elements
    }

    /// Parses a key/value-alternating archive, preserving disk order and every
    /// duplicate key.
    ///
    /// Returns `nil` when the file is missing or is not that shape at all.
    /// Individual malformed pairs are skipped and logged.
    static func entries<Payload: Decodable>(
        ofPayload payloadType: Payload.Type,
        inKeyedArchiveAt url: URL
    ) -> [Entry<Payload>]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        } catch {
            #log(.error, "Bookmark migration: \(url.lastPathComponent, privacy: .public) could not be parsed, nothing migrated from it: \(error, privacy: .public)")
            return nil
        }

        guard let flattened = jsonObject as? [Any] else {
            #log(.error, "Bookmark migration: \(url.lastPathComponent, privacy: .public) is not the expected key/value array, nothing migrated from it")
            return nil
        }

        var entries: [Entry<Payload>] = []
        var pairIndex = 0
        while pairIndex + 1 < flattened.count {
            defer { pairIndex += 2 }
            do {
                let source = try JSONDecoder.decodeFromJSONObject(RuntimeSource.self, flattened[pairIndex])
                let payload = try JSONDecoder.decodeFromJSONObject(Payload.self, flattened[pairIndex + 1])
                entries.append(Entry(source: source, payload: payload))
            } catch {
                #log(.error, "Bookmark migration: skipped the pair at index \(pairIndex, privacy: .public) of \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        if flattened.count.isMultiple(of: 2) == false {
            #log(.error, "Bookmark migration: \(url.lastPathComponent, privacy: .public) has an odd element count; the trailing key had no value and was skipped")
        }
        return entries
    }

    // MARK: - Mapping

    static func migrateImageBookmarks(
        from entries: [Entry<[RuntimeImageBookmark]>]
    ) -> Outcome<[RuntimeImageBookmark]> {
        migrate(entries: entries, merging: deduplicatedUnion)
    }

    static func migrateObjectBookmarks(
        from entries: [Entry<[String: [RuntimeObjectBookmark]]>]
    ) -> Outcome<[String: [RuntimeObjectBookmark]]> {
        migrate(entries: entries) { existing, incoming in
            var merged = existing
            for (imagePath, incomingBookmarks) in incoming {
                merged[imagePath] = deduplicatedUnion(merged[imagePath] ?? [], incomingBookmarks)
            }
            return merged
        }
    }

    /// - Parameter merge: applied when a second source lands on a scope the
    ///   first already occupies. Merging is the *common* case, not an edge one:
    ///   the dead entries a Bonjour peer accumulated — one per relaunch, which
    ///   is the defect being fixed — differ only in a process identifier that
    ///   the scope drops, so they all arrive at the same key.
    private static func migrate<Payload>(
        entries: [Entry<Payload>],
        merging merge: (Payload, Payload) -> Payload
    ) -> Outcome<Payload> {
        var migrated: [String: Payload] = [:]
        var discardedSourceCount = 0
        var mergedSourceCount = 0

        for entry in entries {
            guard let scope = RuntimeBookmarkScope.recovered(from: entry.source) else {
                // No stable identity can be derived, so there is no key a
                // running engine would ever look under. Filing it anyway would
                // look like a successful migration and read as an empty list
                // forever.
                discardedSourceCount += 1
                #log(.error, "Bookmark migration: dropped the entries of \(String(describing: entry.source)) — its identifier carries no stable identity")
                continue
            }
            let key = scope.bookmarkKey
            if let existing = migrated[key] {
                mergedSourceCount += 1
                migrated[key] = merge(existing, entry.payload)
            } else {
                migrated[key] = entry.payload
            }
        }

        #log(.info, "Bookmark migration: \(migrated.count, privacy: .public) scope(s) from \(entries.count, privacy: .public) source(s); merged \(mergedSourceCount, privacy: .public), discarded \(discardedSourceCount, privacy: .public)")
        return Outcome(migrated: migrated, discardedSourceCount: discardedSourceCount, mergedSourceCount: mergedSourceCount)
    }

    /// Concatenation with duplicates removed, earlier occurrences winning.
    ///
    /// Deliberately not "keep the newest": nothing on disk carries a timestamp,
    /// so there is no basis on which to call one entry newer than another, and
    /// inventing one would silently discard bookmarks the user still has.
    static func deduplicatedUnion<Element: Hashable>(_ first: [Element], _ second: [Element]) -> [Element] {
        var seen = Set<Element>()
        var result: [Element] = []
        result.reserveCapacity(first.count + second.count)
        for element in first + second where seen.insert(element).inserted {
            result.append(element)
        }
        return result
    }
}
