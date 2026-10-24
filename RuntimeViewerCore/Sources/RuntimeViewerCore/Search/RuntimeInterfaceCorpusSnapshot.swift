import Foundation
import Semantic

/// An image's corpus as derived data: what the corpus store writes when a
/// build is done, and reads back before it would print.
///
/// The bulk — texts, spans, identifiers, visibility regions, members — goes
/// in flat columns, one for all entries, each compressed on its own; the
/// entries column records where each entry ends in every other one. Objects
/// and the summary, irregular and comparatively small, go as binary property
/// lists. The members went that way too until a read of AppKit's corpus
/// spent half its 0.6 s decoding them (proposal decision log, 2026-10-24).
///
/// Reading back checks everything a reader of these types would trap on
/// before the value that would trap is made: the containers' checks first,
/// then, entry by entry, text and spans as `FrozenSemanticString`'s decoder
/// checks them, regions against the text and its span boundaries, condition
/// indices, option names (`VisibilityCondition.Requirement.init` has
/// preconditions), and nested ranges. Once built, the corpus is walked span
/// by span and projected with every option on and with every option off,
/// while the store's reading marker is still in place — see
/// `RuntimeDerivedDataReadingMarker`.
enum RuntimeInterfaceCorpusSnapshot {
    /// Members are listed by category, the order the corpus prints them in;
    /// part of the variant so that a corpus that follows another order one
    /// day is another file.
    static let memberOrderName = "ByCategory"

    static func variant(for transformer: Transformer.Configuration) -> String {
        "\(transformer.derivedDataDigest)-\(memberOrderName)"
    }

    enum Section: UInt32, CaseIterable {
        case summary = 1
        case objects
        case memberNames
        case text
        case spanLengths
        case spanTypeCodes
        case spanIdentifierIndices
        case identifiers
        case regions
        case conditions
        case nestedDefinitionRanges
        case entries
        /// One byte per member: its kind's index in `RuntimeMemberKind.allCases`,
        /// the top bit set for a static member.
        case memberAttributes
        /// One `UInt32` per member: its line, or zero for none.
        case memberLineNumbers

        var identifier: RuntimeDerivedDataContainer.SectionIdentifier {
            .init(rawValue: rawValue)
        }
    }

    /// Where an entry ends in each column, counted from the start of the
    /// column in that column's own unit.
    private enum EntryColumn: Int, CaseIterable {
        case textByteEnd
        case spanEnd
        case identifierEnd
        case regionEnd
        case conditionEnd
        case nestedDefinitionRangeEnd
        case memberEnd
    }

    private static let staticMemberFlag: UInt8 = 0x80

    private static let memberKinds = RuntimeMemberKind.allCases

    private struct Summary: Codable {
        var summary: RuntimeInterfaceCorpusBuildSummary
        var transformer: Transformer.Configuration
        var entryCount: Int
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case inconsistent(String)
        case otherTransformer

        var description: String {
            switch self {
            case .inconsistent(let reason): "the stored corpus is inconsistent: \(reason)"
            case .otherTransformer: "the stored corpus was printed with another transformer"
            }
        }
    }

    // MARK: - Writing

    /// What a corpus printed this process's addresses into is not written:
    /// an opaque type the demangler could not name prints as the absolute
    /// address of its descriptor, which the next launch moves.
    static func printsProcessAddresses(_ corpus: RuntimeInterfaceCorpusStore.ImageCorpus) -> Bool {
        let marker = Array("opaque type symbolic reference 0x".utf8)
        return corpus.entries.contains { entry in
            var text = entry.interface.text
            return text.withUTF8 { bytes in
                guard bytes.count >= marker.count, let base = bytes.baseAddress else { return false }
                return marker.withUnsafeBufferPointer { markerBytes in
                    memmem(base, bytes.count, markerBytes.baseAddress!, markerBytes.count) != nil
                }
            }
        }
    }

    /// The sections of `corpus`, compressed.
    static func containerBuilder(for corpus: RuntimeInterfaceCorpusStore.ImageCorpus) throws -> RuntimeDerivedDataContainer.Builder {
        var text = Data()
        var spanLengths = Data()
        var spanTypeCodes = Data()
        var spanIdentifierIndices = Data()
        var identifiers = Data()
        var regions = Data()
        var conditions = Data()
        var nestedDefinitionRanges = Data()
        var memberNames = Data()
        var memberAttributes = Data()
        var memberLineNumbers = Data()
        var entries = Data()
        var spanCount: UInt32 = 0
        var identifierCount: UInt32 = 0
        var regionCount: UInt32 = 0
        var conditionCount: UInt32 = 0
        var nestedDefinitionRangeCount: UInt32 = 0
        var memberCount: UInt32 = 0

        let totalTextByteCount = corpus.entries.reduce(0) { $0 + $1.interface.text.utf8.count }
        let totalSpanCount = corpus.entries.reduce(0) { $0 + $1.interface.spans.count }
        guard totalTextByteCount <= Int(UInt32.max), totalSpanCount <= Int(UInt32.max) else {
            throw Error.inconsistent("too large to store")
        }
        text.reserveCapacity(totalTextByteCount)
        spanLengths.reserveCapacity(totalSpanCount * 2)
        spanTypeCodes.reserveCapacity(totalSpanCount)
        spanIdentifierIndices.reserveCapacity(totalSpanCount * 4)

        for entry in corpus.entries {
            text.append(contentsOf: entry.interface.text.utf8)
            for span in entry.interface.spans {
                spanLengths.appendLittleEndian(span.length)
                spanTypeCodes.append(span.typeCode)
                spanIdentifierIndices.appendLittleEndian(span.identifierIndex)
            }
            spanCount += UInt32(entry.interface.spans.count)
            for identifier in entry.interface.identifierTable {
                identifiers.appendLengthPrefixed(identifier)
            }
            identifierCount += UInt32(entry.interface.identifierTable.count)
            for region in entry.visibilityRegions.regions {
                regions.appendLittleEndian(region.utf8Offset)
                regions.appendLittleEndian(region.utf8Length)
                regions.appendLittleEndian(region.conditionIndex)
            }
            regionCount += UInt32(entry.visibilityRegions.regions.count)
            for condition in entry.visibilityRegions.conditions {
                conditions.appendLittleEndian(UInt32(condition.alternatives.count))
                for alternative in condition.alternatives {
                    conditions.appendLittleEndian(UInt32(alternative.count))
                    for requirement in alternative {
                        conditions.append(requirement.isEnabled ? 1 : 0)
                        conditions.appendLengthPrefixed(requirement.option)
                    }
                }
            }
            conditionCount += UInt32(entry.visibilityRegions.conditions.count)
            for range in entry.nestedDefinitionRanges {
                nestedDefinitionRanges.appendLittleEndian(Int64(range.lowerBound))
                nestedDefinitionRanges.appendLittleEndian(Int64(range.upperBound))
            }
            nestedDefinitionRangeCount += UInt32(entry.nestedDefinitionRanges.count)
            for member in entry.members {
                // `declarationText` is the name itself in a corpus entry; see
                // `RuntimeInterfaceCorpusEntry.members`.
                memberNames.appendLengthPrefixed(member.name)
                let kindIndex = UInt8(memberKinds.firstIndex(of: member.kind)!)
                memberAttributes.append(member.isStatic ? kindIndex | staticMemberFlag : kindIndex)
                memberLineNumbers.appendLittleEndian(member.lineNumber.flatMap { UInt32(exactly: $0) } ?? 0)
            }
            memberCount += UInt32(entry.members.count)

            for column in EntryColumn.allCases {
                let end: UInt32 = switch column {
                case .textByteEnd: UInt32(text.count)
                case .spanEnd: spanCount
                case .identifierEnd: identifierCount
                case .regionEnd: regionCount
                case .conditionEnd: conditionCount
                case .nestedDefinitionRangeEnd: nestedDefinitionRangeCount
                case .memberEnd: memberCount
                }
                entries.appendLittleEndian(end)
            }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var builder = RuntimeDerivedDataContainer.Builder()
        builder.append(try encoder.encode(Summary(summary: corpus.summary, transformer: corpus.transformer, entryCount: corpus.entries.count)), as: Section.summary.identifier)
        builder.append(try encoder.encode(corpus.entries.map(\.object)), as: Section.objects.identifier)
        builder.append(memberNames, as: Section.memberNames.identifier)
        builder.append(memberAttributes, as: Section.memberAttributes.identifier)
        builder.append(memberLineNumbers, as: Section.memberLineNumbers.identifier)
        builder.append(text, as: Section.text.identifier)
        builder.append(spanLengths, as: Section.spanLengths.identifier)
        builder.append(spanTypeCodes, as: Section.spanTypeCodes.identifier)
        builder.append(spanIdentifierIndices, as: Section.spanIdentifierIndices.identifier)
        builder.append(identifiers, as: Section.identifiers.identifier)
        builder.append(regions, as: Section.regions.identifier)
        builder.append(conditions, as: Section.conditions.identifier)
        builder.append(nestedDefinitionRanges, as: Section.nestedDefinitionRanges.identifier)
        builder.append(entries, as: Section.entries.identifier)
        return builder
    }

    // MARK: - Reading

    /// The corpus in `container`, checked, built, and walked through. Throws
    /// for anything inconsistent, or for a corpus printed with another
    /// configuration than `transformer`.
    static func corpus(from container: RuntimeDerivedDataContainer, transformer: Transformer.Configuration) throws -> RuntimeInterfaceCorpusStore.ImageCorpus {
        let decoder = PropertyListDecoder()
        let summary = try decoder.decode(Summary.self, from: container.section(Section.summary.identifier))
        guard summary.transformer == transformer else { throw Error.otherTransformer }
        let objects = try decoder.decode([RuntimeObject].self, from: container.section(Section.objects.identifier))
        let text = try container.section(Section.text.identifier)
        let spanLengthData = try container.section(Section.spanLengths.identifier)
        let spanTypeCodeData = try container.section(Section.spanTypeCodes.identifier)
        let spanIdentifierIndexData = try container.section(Section.spanIdentifierIndices.identifier)
        let entryColumnData = try container.section(Section.entries.identifier)
        var identifierReader = RuntimeDerivedDataByteReader(try container.section(Section.identifiers.identifier))
        var regionReader = RuntimeDerivedDataByteReader(try container.section(Section.regions.identifier))
        var conditionReader = RuntimeDerivedDataByteReader(try container.section(Section.conditions.identifier))
        var nestedRangeReader = RuntimeDerivedDataByteReader(try container.section(Section.nestedDefinitionRanges.identifier))
        var memberNameReader = RuntimeDerivedDataByteReader(try container.section(Section.memberNames.identifier))
        let memberAttributes = [UInt8](try container.section(Section.memberAttributes.identifier))
        let memberLineNumberData = try container.section(Section.memberLineNumbers.identifier)

        let entryCount = summary.entryCount
        let columnCount = EntryColumn.allCases.count
        guard entryCount >= 0,
              objects.count == entryCount,
              entryColumnData.count == entryCount * columnCount * 4,
              summary.summary.objectCount == entryCount
        else { throw Error.inconsistent("the sections disagree on the number of entries") }
        let spanCount = spanTypeCodeData.count
        guard spanLengthData.count == spanCount * 2, spanIdentifierIndexData.count == spanCount * 4 else {
            throw Error.inconsistent("the span columns have different lengths")
        }
        guard memberLineNumberData.count == memberAttributes.count * 4 else {
            throw Error.inconsistent("the member columns have different lengths")
        }
        let memberLineNumbers = littleEndianIntegers(of: UInt32.self, in: memberLineNumberData)
        let spanLengths = littleEndianIntegers(of: UInt16.self, in: spanLengthData)
        let spanTypeCodes = [UInt8](spanTypeCodeData)
        let spanIdentifierIndices = littleEndianIntegers(of: UInt32.self, in: spanIdentifierIndexData)
        let entryColumns = littleEndianIntegers(of: UInt32.self, in: entryColumnData)

        var entries: [RuntimeInterfaceCorpusEntry] = []
        entries.reserveCapacity(entryCount)
        var start = [Int](repeating: 0, count: columnCount)
        try text.withUnsafeBytes { (textBytes: UnsafeRawBufferPointer) in
            for entryIndex in 0 ..< entryCount {
                var end = [Int](repeating: 0, count: columnCount)
                for column in EntryColumn.allCases {
                    end[column.rawValue] = Int(entryColumns[entryIndex * columnCount + column.rawValue])
                    guard end[column.rawValue] >= start[column.rawValue] else {
                        throw Error.inconsistent("entry \(entryIndex) ends before it starts")
                    }
                }
                let textRange = start[EntryColumn.textByteEnd.rawValue] ..< end[EntryColumn.textByteEnd.rawValue]
                let spanRange = start[EntryColumn.spanEnd.rawValue] ..< end[EntryColumn.spanEnd.rawValue]
                guard textRange.upperBound <= textBytes.count, spanRange.upperBound <= spanCount else {
                    throw Error.inconsistent("entry \(entryIndex) runs past its columns")
                }

                // Spans: no empty one, every boundary on a Unicode scalar, the
                // lengths covering the text exactly.
                var spans: [FrozenSemanticString.Span] = []
                spans.reserveCapacity(spanRange.count)
                var spanBoundaries: [Int] = [0]
                spanBoundaries.reserveCapacity(spanRange.count + 1)
                var coveredByteCount = 0
                for spanIndex in spanRange {
                    let length = spanLengths[spanIndex]
                    guard length > 0 else { throw Error.inconsistent("entry \(entryIndex) has an empty span") }
                    guard coveredByteCount < textRange.count,
                          !isContinuationByte(textBytes[textRange.lowerBound + coveredByteCount])
                    else { throw Error.inconsistent("a span of entry \(entryIndex) starts inside a scalar or past the text") }
                    coveredByteCount += Int(length)
                    spanBoundaries.append(coveredByteCount)
                    spans.append(FrozenSemanticString.Span(length: length, typeCode: spanTypeCodes[spanIndex], identifierIndex: spanIdentifierIndices[spanIndex]))
                }
                guard coveredByteCount == textRange.count else {
                    throw Error.inconsistent("the spans of entry \(entryIndex) cover \(coveredByteCount) of its \(textRange.count) bytes")
                }
                if textRange.upperBound < textBytes.count, isContinuationByte(textBytes[textRange.upperBound]) {
                    throw Error.inconsistent("entry \(entryIndex) ends inside a scalar")
                }
                // Valid UTF-8 as a whole, which the boundaries alone do not
                // prove.
                guard let interfaceText = String(data: text[(text.startIndex + textRange.lowerBound) ..< (text.startIndex + textRange.upperBound)], encoding: .utf8),
                      interfaceText.utf8.count == textRange.count
                else { throw Error.inconsistent("the text of entry \(entryIndex) is not UTF-8") }

                var identifierTable: [String] = []
                let identifierCount = end[EntryColumn.identifierEnd.rawValue] - start[EntryColumn.identifierEnd.rawValue]
                identifierTable.reserveCapacity(identifierCount)
                for _ in 0 ..< identifierCount {
                    identifierTable.append(try identifierReader.readLengthPrefixedString())
                }

                let conditionCount = end[EntryColumn.conditionEnd.rawValue] - start[EntryColumn.conditionEnd.rawValue]
                var conditions: [VisibilityCondition] = []
                conditions.reserveCapacity(conditionCount)
                for _ in 0 ..< conditionCount {
                    conditions.append(try readCondition(from: &conditionReader))
                }

                let regionCount = end[EntryColumn.regionEnd.rawValue] - start[EntryColumn.regionEnd.rawValue]
                var regions: [VisibilityRegionTable.Region] = []
                regions.reserveCapacity(regionCount)
                for _ in 0 ..< regionCount {
                    let region = VisibilityRegionTable.Region(
                        utf8Offset: try regionReader.readUInt32(),
                        utf8Length: try regionReader.readUInt32(),
                        conditionIndex: try regionReader.readUInt32()
                    )
                    let regionStart = Int(region.utf8Offset)
                    let regionEnd = regionStart + Int(region.utf8Length)
                    guard regionEnd <= textRange.count,
                          Int(region.conditionIndex) < conditions.count,
                          isBoundary(regionStart, in: spanBoundaries),
                          isBoundary(regionEnd, in: spanBoundaries)
                    else { throw Error.inconsistent("a visibility region of entry \(entryIndex) is not a run of its spans") }
                    regions.append(region)
                }

                let nestedRangeCount = end[EntryColumn.nestedDefinitionRangeEnd.rawValue] - start[EntryColumn.nestedDefinitionRangeEnd.rawValue]
                var nestedDefinitionRanges: [Range<Int>] = []
                nestedDefinitionRanges.reserveCapacity(nestedRangeCount)
                for _ in 0 ..< nestedRangeCount {
                    let lowerBound = try nestedRangeReader.readInt64()
                    let upperBound = try nestedRangeReader.readInt64()
                    guard lowerBound >= 0, lowerBound <= upperBound, upperBound <= Int64(textRange.count) else {
                        throw Error.inconsistent("a nested definition range of entry \(entryIndex) is out of its text")
                    }
                    nestedDefinitionRanges.append(Int(lowerBound) ..< Int(upperBound))
                }

                let memberRange = start[EntryColumn.memberEnd.rawValue] ..< end[EntryColumn.memberEnd.rawValue]
                guard memberRange.upperBound <= memberAttributes.count else {
                    throw Error.inconsistent("entry \(entryIndex) runs past its members")
                }
                var members: [RuntimeMemberDeclaration] = []
                members.reserveCapacity(memberRange.count)
                for memberIndex in memberRange {
                    let name = try memberNameReader.readLengthPrefixedString()
                    let attributes = memberAttributes[memberIndex]
                    let kindIndex = Int(attributes & ~staticMemberFlag)
                    guard kindIndex < memberKinds.count else {
                        throw Error.inconsistent("a member of entry \(entryIndex) has a kind this build does not know")
                    }
                    let lineNumber = memberLineNumbers[memberIndex]
                    members.append(RuntimeMemberDeclaration(
                        name: name,
                        kind: memberKinds[kindIndex],
                        isStatic: attributes & staticMemberFlag != 0,
                        declarationText: name,
                        lineNumber: lineNumber == 0 ? nil : Int(lineNumber)
                    ))
                }

                entries.append(RuntimeInterfaceCorpusEntry(
                    object: objects[entryIndex],
                    interface: FrozenSemanticString(text: interfaceText, spans: spans, identifierTable: identifierTable),
                    visibilityRegions: VisibilityRegionTable(regions: regions, conditions: conditions),
                    members: members,
                    nestedDefinitionRanges: nestedDefinitionRanges
                ))
                start = end
            }
        }
        guard start[EntryColumn.textByteEnd.rawValue] == text.count,
              start[EntryColumn.spanEnd.rawValue] == spanCount,
              start[EntryColumn.memberEnd.rawValue] == memberAttributes.count,
              identifierReader.isAtEnd, regionReader.isAtEnd, conditionReader.isAtEnd, nestedRangeReader.isAtEnd, memberNameReader.isAtEnd
        else { throw Error.inconsistent("the columns hold more than the entries take") }

        walkThrough(entries)

        let byteCount = entries.reduce(0) { $0 + $1.byteCount }
        return RuntimeInterfaceCorpusStore.ImageCorpus(
            entries: entries,
            summary: RuntimeInterfaceCorpusBuildSummary(objectCount: entries.count, skippedCount: summary.summary.skippedCount, byteCount: byteCount),
            transformer: transformer,
            lastSearchedAt: Date()
        )
    }

    /// Every read of the corpus that walks a text, once: each entry's spans,
    /// and each entry with regions projected with every option on and with
    /// every option off. Whatever would trap there traps now, while the
    /// reading marker is still beside the file.
    static func walkThrough(_ entries: [RuntimeInterfaceCorpusEntry]) {
        func walk(_ string: FrozenSemanticString) {
            string.enumerateSpans { _, _, _ in }
        }
        for entry in entries {
            walk(entry.interface)
            guard !entry.visibilityRegions.isEmpty else { continue }
            walk(entry.visibilityRegions.projection(of: entry.interface) { _ in true }.text)
            walk(entry.visibilityRegions.projection(of: entry.interface) { _ in false }.text)
            _ = entry.visibilityRegions.hiddenUTF8Ranges(inTextOfUTF8Count: entry.interface.text.utf8.count) { _ in false }
        }
    }

    /// One condition, its option names checked before any requirement is
    /// made of them.
    private static func readCondition(from reader: inout RuntimeDerivedDataByteReader) throws -> VisibilityCondition {
        let alternativeCount = Int(try reader.readUInt32())
        var alternatives: [[VisibilityCondition.Requirement]] = []
        for _ in 0 ..< alternativeCount {
            let requirementCount = Int(try reader.readUInt32())
            var requirements: [VisibilityCondition.Requirement] = []
            for _ in 0 ..< requirementCount {
                let isEnabled = try reader.readUInt8()
                let option = try reader.readLengthPrefixedString()
                guard isEnabled <= 1, !option.isEmpty, !option.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                    throw Error.inconsistent("a visibility condition names an option no printer could have written")
                }
                requirements.append(VisibilityCondition.Requirement(option: option, isEnabled: isEnabled == 1))
            }
            alternatives.append(requirements)
        }
        return VisibilityCondition(alternatives: alternatives)
    }

    /// `data` as consecutive little-endian integers; its length is a
    /// multiple of theirs, which the caller checked.
    private static func littleEndianIntegers<Integer: FixedWidthInteger>(of type: Integer.Type, in data: Data) -> [Integer] {
        let count = data.count / MemoryLayout<Integer>.size
        return data.withUnsafeBytes { bytes in
            (0 ..< count).map { index in
                Integer(littleEndian: bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<Integer>.size, as: Integer.self))
            }
        }
    }

    private static func isContinuationByte(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }

    /// Whether `offset` is one of `boundaries`, which ascend.
    private static func isBoundary(_ offset: Int, in boundaries: [Int]) -> Bool {
        var lowerBound = 0
        var upperBound = boundaries.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if boundaries[middle] < offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound < boundaries.count && boundaries[lowerBound] == offset
    }
}
