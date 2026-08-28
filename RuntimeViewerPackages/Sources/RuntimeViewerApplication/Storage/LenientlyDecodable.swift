import Foundation

/// A container that can be rebuilt from parsed JSON while discarding only the
/// parts that fail, rather than failing whole.
///
/// `Decodable` is all-or-nothing by design: one malformed element and the
/// entire value is gone. That is the right default almost everywhere, and the
/// wrong one for a user's bookmarks, where a single unreadable entry should
/// cost that entry and nothing more.
public protocol LenientlyDecodable {
    /// Rebuilds as much of `jsonObject` as decodes cleanly.
    ///
    /// Appends one line to `diagnostics` per piece dropped, so the caller can
    /// say what was lost instead of silently shrinking. Returns `nil` only when
    /// `jsonObject` is not even the right *shape* — an array where an object
    /// belongs — which is a corrupt file rather than a corrupt entry, and is
    /// handled differently by the caller.
    static func decodedLeniently(from jsonObject: Any, diagnostics: inout [String]) -> Self?
}

extension Array: LenientlyDecodable where Element: Decodable {
    public static func decodedLeniently(from jsonObject: Any, diagnostics: inout [String]) -> [Element]? {
        guard let rawElements = jsonObject as? [Any] else { return nil }
        var decodedElements: [Element] = []
        decodedElements.reserveCapacity(rawElements.count)
        for (offset, rawElement) in rawElements.enumerated() {
            do {
                decodedElements.append(try JSONDecoder.decodeFromJSONObject(Element.self, rawElement))
            } catch {
                diagnostics.append("dropped element at index \(offset): \(error)")
            }
        }
        return decodedElements
    }
}

extension Dictionary: LenientlyDecodable where Key == String, Value: LenientlyDecodable {
    public static func decodedLeniently(from jsonObject: Any, diagnostics: inout [String]) -> [String: Value]? {
        guard let rawObject = jsonObject as? [String: Any] else { return nil }
        var decodedObject: [String: Value] = [:]
        // Sorted so that the diagnostics of two runs over the same file read
        // the same way; `Dictionary` iteration order is not stable across
        // launches.
        for key in rawObject.keys.sorted() {
            var nestedDiagnostics: [String] = []
            guard let value = Value.decodedLeniently(from: rawObject[key]!, diagnostics: &nestedDiagnostics) else {
                diagnostics.append("dropped key \(key): its value is not the expected shape")
                continue
            }
            decodedObject[key] = value
            diagnostics.append(contentsOf: nestedDiagnostics.map { "under key \(key): \($0)" })
        }
        return decodedObject
    }
}

extension JSONDecoder {
    /// Decodes one already-parsed JSON value.
    ///
    /// Wrapped in an array on the way through because a bare scalar is not a
    /// legal top-level JSON document everywhere this runs, and a bookmark
    /// payload is free to be one.
    static func decodeFromJSONObject<Decoded: Decodable>(_ type: Decoded.Type, _ jsonObject: Any) throws -> Decoded {
        let data = try JSONSerialization.data(withJSONObject: [jsonObject])
        return try JSONDecoder().decode([Decoded].self, from: data)[0]
    }
}
