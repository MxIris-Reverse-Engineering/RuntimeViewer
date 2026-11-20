import Foundation

/// What a `dlerror()` message after a refused `dlopen` says, read apart.
///
/// dyld words the message in a few fixed shapes (dyld-1323: `DyldAPIs.cpp`,
/// `JustInTimeLoader.cpp`, `Loader.cpp`):
///
/// ```
/// dlopen(<path>, 0x0001): Library not loaded: <load name>
///   Referenced from: <UUID> <image>
///   Reason: tried: '<path>' (no such file), '<path>' (no such file, not in dyld cache), …
///
/// dlopen(<path>, 0x0001): Symbol not found: <symbol>
///   Referenced from: <UUID> <image>
///   Expected in:     <UUID> <image>
///
/// dlopen(<path>, 0x0001): tried: '<path>' (mach-o file, but is an incompatible architecture (have 'x86_64', need 'arm64e or arm64')), …
/// ```
///
/// A reason may itself hold parentheses, commas and quotes, and one shape puts
/// text after the parenthesis (`'<path>' (blocked by sandbox), not in dyld
/// cache`), so the `tried:` list is scanned item by item rather than split.
struct DyldLoadFailureMessage: Sendable, Hashable {
    var failure: RuntimeImageLoadDiagnosis.Failure
    /// The path given to `dlopen`, from the message's `dlopen(<path>, <mode>):` prefix.
    var requestedImagePath: String?
    var triedPaths: [RuntimeImageLoadDiagnosis.TriedPath]

    init(parsing message: String) {
        var body = message
        var requestedImagePath: String?
        if body.hasPrefix("dlopen("), let prefixEnd = body.range(of: "): ") {
            let inside = body[body.index(body.startIndex, offsetBy: "dlopen(".count) ..< prefixEnd.lowerBound]
            if let modeSeparator = inside.range(of: ", 0x", options: .backwards) {
                requestedImagePath = String(inside[..<modeSeparator.lowerBound])
            } else {
                requestedImagePath = String(inside)
            }
            body = String(body[prefixEnd.upperBound...])
        }
        self.requestedImagePath = requestedImagePath

        var missingInstallName: String?
        var symbolName: String?
        var referencingImagePath: String?
        var expectedInImagePath: String?
        var reasonText: String?

        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex == 0 {
                if let rest = line.removingPrefix("Library not loaded: ") {
                    missingInstallName = rest
                } else if let rest = line.removingPrefix("Symbol not found: ") {
                    symbolName = rest
                } else if line.hasPrefix("tried: ") {
                    reasonText = line
                }
                continue
            }
            if let rest = line.removingPrefix("Referenced from:") {
                referencingImagePath = Self.imagePath(afterUUIDIn: rest)
            } else if let rest = line.removingPrefix("Expected in:") {
                expectedInImagePath = Self.imagePath(afterUUIDIn: rest)
            } else if let rest = line.removingPrefix("Reason: ") {
                reasonText = rest
            }
        }

        let triedPaths = reasonText.map(Self.triedPaths(in:)) ?? []
        self.triedPaths = triedPaths

        if let symbolName {
            failure = .init(
                kind: .symbolNotFound,
                symbolName: symbolName,
                referencingImagePath: referencingImagePath,
                expectedInImagePath: expectedInImagePath
            )
        } else if let incompatible = triedPaths.first(where: { Self.isIncompatibility($0.reason) }) {
            failure = .init(
                kind: .incompatibleImage,
                missingInstallName: missingInstallName ?? incompatible.path,
                referencingImagePath: referencingImagePath,
                reason: incompatible.reason
            )
        } else if missingInstallName != nil || !triedPaths.isEmpty {
            failure = .init(
                kind: .imageNotFound,
                missingInstallName: missingInstallName ?? requestedImagePath,
                referencingImagePath: referencingImagePath,
                reason: reasonText.flatMap { triedPaths.isEmpty ? $0 : nil }
            )
        } else {
            failure = .init(kind: .unrecognized, reason: body.isEmpty ? nil : body)
        }
    }

    /// `<UUID> /path/to/image` → `/path/to/image`; the UUID is optional.
    private static func imagePath(afterUUIDIn text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<"), let uuidEnd = trimmed.firstIndex(of: ">") else { return trimmed }
        return trimmed[trimmed.index(after: uuidEnd)...].trimmingCharacters(in: .whitespaces)
    }

    private static func isIncompatibility(_ reason: String) -> Bool {
        reason.contains("incompatible architecture") || reason.contains("incompatible platform")
    }

    /// Reads `tried: '<path>' (<reason>), '<path>' (<reason>)…` item by item.
    static func triedPaths(in reasonText: String) -> [RuntimeImageLoadDiagnosis.TriedPath] {
        guard let list = reasonText.removingPrefix("tried: ") else { return [] }
        var items: [RuntimeImageLoadDiagnosis.TriedPath] = []
        var cursor = list.startIndex
        while cursor < list.endIndex {
            guard let pathStart = list[cursor...].firstIndex(of: "'") else { break }
            let afterQuote = list.index(after: pathStart)
            guard let pathEnd = list[afterQuote...].firstIndex(of: "'") else { break }
            let path = String(list[afterQuote ..< pathEnd])
            cursor = list.index(after: pathEnd)
            var reason = ""
            // The reason is a balanced parenthesis that may hold more of them.
            let rest = list[cursor...]
            if rest.hasPrefix(" (") {
                let openingParenthesis = list.index(after: cursor)
                let reasonStart = list.index(after: openingParenthesis)
                var depth = 0
                var index = openingParenthesis
                while index < list.endIndex {
                    let character = list[index]
                    if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    index = list.index(after: index)
                }
                reason = String(list[reasonStart ..< min(index, list.endIndex)])
                cursor = index < list.endIndex ? list.index(after: index) : list.endIndex
            }
            // Text between the parenthesis and the next item belongs to this one
            // (`(blocked by sandbox), not in dyld cache`).
            let nextItem = list[cursor...].range(of: ", '")
            let trailingEnd = nextItem?.lowerBound ?? list.endIndex
            let trailing = list[cursor ..< trailingEnd]
                .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            if !trailing.isEmpty {
                reason = reason.isEmpty ? trailing : reason + ", " + trailing
            }
            items.append(.init(path: path, reason: reason))
            cursor = nextItem.map { list.index(after: $0.lowerBound) } ?? list.endIndex
        }
        return items
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
