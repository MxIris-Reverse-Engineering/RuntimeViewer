/// The Objective-C protocol copies one search has reported hits in, by name,
/// as the text it read them in.
///
/// The compiler emits a protocol into every image that saw its declaration,
/// and the sidebar lists every copy on purpose
/// (`ResolvedIssues/2026-08-05-objc-protocol-ownership-filter.md`), so one
/// search over several images meets the same declaration once per carrier:
/// `NSObject`'s in nearly every image. A copy that reads exactly like one
/// already reported adds nothing but the same hits again. Copies that read
/// differently — an image built against an older header — are not repeats,
/// and keep their own hits.
struct RuntimeInterfaceRepeatedProtocolCopies {
    private var reportedTextsByProtocolName: [String: [String]] = [:]

    /// Whether `entry` is an Objective-C protocol copy reading exactly like
    /// one this search already reported hits in.
    func isRepeated(_ entry: RuntimeInterfaceCorpusEntry, readingAs text: String) -> Bool {
        guard Self.isProtocolCopy(entry) else { return false }
        return reportedTextsByProtocolName[entry.object.name]?.contains(text) ?? false
    }

    /// Remembers a protocol copy the search reported hits in, as it read it.
    mutating func recordReported(_ entry: RuntimeInterfaceCorpusEntry, readingAs text: String) {
        guard Self.isProtocolCopy(entry) else { return }
        reportedTextsByProtocolName[entry.object.name, default: []].append(text)
    }

    private static func isProtocolCopy(_ entry: RuntimeInterfaceCorpusEntry) -> Bool {
        entry.object.kind == .objc(.type(.protocol))
    }
}
