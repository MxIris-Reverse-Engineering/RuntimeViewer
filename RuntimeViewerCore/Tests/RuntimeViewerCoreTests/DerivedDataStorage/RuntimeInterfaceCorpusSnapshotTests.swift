import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// A corpus as derived data: what is written reads back entry for entry, and
/// every way the stored columns can disagree with each other is an error the
/// read reports — never a value that traps later, in a search.
@Suite("RuntimeInterfaceCorpusSnapshot")
struct RuntimeInterfaceCorpusSnapshotTests {
    typealias Section = RuntimeInterfaceCorpusSnapshot.Section

    private static let imagePath = "/images/Snapshot"

    private static let header = RuntimeDerivedDataContainer.Header(
        kind: RuntimeDerivedDataKind.interfaceCorpus.rawValue,
        variant: RuntimeInterfaceCorpusSnapshot.variant(for: .default),
        imagePath: imagePath,
        systemDirectoryName: DerivedDataTestIdentities.system.directoryName,
        producerDigest: DerivedDataTestIdentities.producer.digest
    )

    /// Three entries: one with multi-byte text, an identifier, a visibility
    /// region and a nested block; one plain; one empty.
    private static func makeCorpus() -> RuntimeInterfaceCorpusStore.ImageCorpus {
        let printed = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, "Café")
            Standard(" {\n")
            VisibilityRegion(.enabled("test.comments")) {
                Standard("    ")
                Comment("✓ 中文 comment")
                Standard("\n")
            }
            VisibilityRegion(.any([.disabled("test.members"), .enabled("test.all")])) {
                Standard("    ")
                Keyword("var")
                Standard(" ")
                Variable("naïve")
                Standard(": Int\n")
            }
            Standard("    struct Inner {}\n}")
        }.frozen()
        let (firstInterface, firstRegions) = printed.separatingVisibilityRegions()
        let innerStart = firstInterface.text.utf8.count - "    struct Inner {}\n}".utf8.count
        let first = RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "Café", displayName: "Café", kind: .swift(.type(.struct)), imagePath: imagePath, children: []),
            interface: firstInterface,
            visibilityRegions: firstRegions,
            members: [RuntimeMemberDeclaration(name: "naïve", kind: .swiftVariable, isStatic: false, declarationText: "", lineNumber: 3)],
            nestedDefinitionRanges: [innerStart ..< innerStart + "    struct Inner {}\n".utf8.count]
        )
        let second = RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: imagePath, children: []),
            interface: SemanticString {
                Keyword("@interface")
                Standard(" ")
                TypeName(kind: .class, "NSObject")
                Standard("\n- (void)method;\n@end")
            }.frozen(),
            members: [RuntimeMemberDeclaration(name: "method", kind: .objcMethod, isStatic: false, declarationText: "", lineNumber: 2)]
        )
        let empty = RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "Empty", displayName: "Empty", kind: .objc(.type(.protocol)), imagePath: imagePath, children: []),
            interface: FrozenSemanticString(text: "", spans: [], identifierTable: []),
            members: []
        )
        let entries = [first, second, empty]
        return RuntimeInterfaceCorpusStore.ImageCorpus(
            entries: entries,
            summary: RuntimeInterfaceCorpusBuildSummary(objectCount: entries.count, skippedCount: 2, byteCount: entries.reduce(0) { $0 + $1.byteCount }),
            transformer: .default,
            lastSearchedAt: Date()
        )
    }

    private static func sections(of corpus: RuntimeInterfaceCorpusStore.ImageCorpus) throws -> [Section: Data] {
        let file = RuntimeDerivedDataContainer.encoded(try RuntimeInterfaceCorpusSnapshot.containerBuilder(for: corpus), header: header)
        let container = try RuntimeDerivedDataContainer(decoding: file, expecting: header)
        var sections: [Section: Data] = [:]
        for section in Section.allCases {
            sections[section] = try container.section(section.identifier)
        }
        return sections
    }

    private static func readCorpus(from sections: [Section: Data], transformer: Transformer.Configuration = .default) throws -> RuntimeInterfaceCorpusStore.ImageCorpus {
        var builder = RuntimeDerivedDataContainer.Builder()
        for section in Section.allCases {
            if let data = sections[section] {
                builder.append(data, as: section.identifier, compression: .none)
            }
        }
        let container = try RuntimeDerivedDataContainer(decoding: RuntimeDerivedDataContainer.encoded(builder, header: header), expecting: header)
        return try RuntimeInterfaceCorpusSnapshot.corpus(from: container, transformer: transformer)
    }

    private static func expectSameEntries(_ restored: [RuntimeInterfaceCorpusEntry], _ original: [RuntimeInterfaceCorpusEntry]) {
        #expect(restored.count == original.count)
        for (restoredEntry, originalEntry) in zip(restored, original) {
            #expect(restoredEntry.object == originalEntry.object)
            #expect(restoredEntry.object.displayName == originalEntry.object.displayName)
            #expect(restoredEntry.object.children == originalEntry.object.children)
            #expect(restoredEntry.object.properties == originalEntry.object.properties)
            #expect(restoredEntry.interface == originalEntry.interface)
            #expect(restoredEntry.interface.spans == originalEntry.interface.spans)
            #expect(restoredEntry.interface.identifierTable == originalEntry.interface.identifierTable)
            #expect(restoredEntry.visibilityRegions == originalEntry.visibilityRegions)
            #expect(restoredEntry.members == originalEntry.members)
            #expect(restoredEntry.memberDeclarationLineRanges == originalEntry.memberDeclarationLineRanges)
            #expect(restoredEntry.nestedDefinitionRanges == originalEntry.nestedDefinitionRanges)
        }
    }

    @Test("A corpus reads back entry for entry")
    func roundTrip() throws {
        let corpus = Self.makeCorpus()
        #expect(!corpus.entries[0].visibilityRegions.isEmpty, "the sample has regions to store")
        let restored = try Self.readCorpus(from: try Self.sections(of: corpus))
        Self.expectSameEntries(restored.entries, corpus.entries)
        #expect(restored.summary == corpus.summary)
        #expect(restored.transformer == corpus.transformer)
    }

    @Test("A corpus printed with another transformer is not read")
    func otherTransformer() throws {
        var transformer = Transformer.Configuration()
        transformer.objc.cType.isEnabled = true
        let sections = try Self.sections(of: Self.makeCorpus())
        #expect(throws: RuntimeInterfaceCorpusSnapshot.Error.self) {
            _ = try Self.readCorpus(from: sections, transformer: transformer)
        }
    }

    @Test("A corpus that prints this process's addresses is told")
    func processAddresses() {
        var corpus = Self.makeCorpus()
        #expect(!RuntimeInterfaceCorpusSnapshot.printsProcessAddresses(corpus))
        let entry = RuntimeInterfaceCorpusEntry(
            object: corpus.entries[1].object,
            interface: SemanticString { Standard("var body: opaque type symbolic reference 0x1A2B3C") }.frozen(),
            members: []
        )
        corpus = RuntimeInterfaceCorpusStore.ImageCorpus(entries: corpus.entries + [entry], summary: corpus.summary, transformer: .default, lastSearchedAt: Date())
        #expect(RuntimeInterfaceCorpusSnapshot.printsProcessAddresses(corpus))
    }

    // MARK: - Damage

    /// One way the columns can disagree: a description, and how it changes
    /// them.
    struct Damage: CustomTestStringConvertible, Sendable {
        let testDescription: String
        let apply: @Sendable (inout [Section: Data]) -> Void
        /// What `FrozenSemanticString`'s own decoder makes of the damaged
        /// first entry, for the damage that its decoder checks too: the
        /// same verdict is expected.
        var isCheckedByTheCodableDecoderToo = false
    }

    private static func replaceLittleEndian<Integer: FixedWidthInteger>(_ value: Integer, at index: Int, in data: inout Data) {
        let byteCount = MemoryLayout<Integer>.size
        let bytes = withUnsafeBytes(of: value.littleEndian) { Data($0) }
        data.replaceSubrange(data.startIndex + index * byteCount ..< data.startIndex + (index + 1) * byteCount, with: bytes)
    }

    private static func littleEndian<Integer: FixedWidthInteger>(_ type: Integer.Type, at index: Int, in data: Data) -> Integer {
        let byteCount = MemoryLayout<Integer>.size
        return data[data.startIndex + index * byteCount ..< data.startIndex + (index + 1) * byteCount].withUnsafeBytes {
            Integer(littleEndian: $0.loadUnaligned(as: Integer.self))
        }
    }

    /// The entries column has seven ends per entry: text bytes, spans,
    /// identifiers, regions, conditions, nested ranges, members.
    private static func entryEndIndex(entry: Int, column: Int) -> Int {
        entry * 7 + column
    }

    static let damages: [Damage] = [
        Damage(testDescription: "a span longer than recorded", apply: { sections in
            let length = littleEndian(UInt16.self, at: 0, in: sections[.spanLengths]!)
            replaceLittleEndian(length + 1, at: 0, in: &sections[.spanLengths]!)
        }, isCheckedByTheCodableDecoderToo: true),
        Damage(testDescription: "a span of no length", apply: { sections in
            replaceLittleEndian(UInt16(0), at: 1, in: &sections[.spanLengths]!)
        }, isCheckedByTheCodableDecoderToo: true),
        Damage(testDescription: "span boundaries inside a scalar", apply: { sections in
            // The first span holding a multi-byte scalar ends right after the
            // scalar's lead byte instead; the next span takes the rest.
            let text = [UInt8](sections[.text]!)
            var spanStart = 0
            var spanIndex = 0
            while true {
                let length = Int(littleEndian(UInt16.self, at: spanIndex, in: sections[.spanLengths]!))
                if let leadByteOffset = (spanStart ..< spanStart + length).first(where: { text[$0] >= 0xC0 }), leadByteOffset + 1 < spanStart + length {
                    let shortenedLength = leadByteOffset + 1 - spanStart
                    let nextLength = littleEndian(UInt16.self, at: spanIndex + 1, in: sections[.spanLengths]!)
                    replaceLittleEndian(UInt16(shortenedLength), at: spanIndex, in: &sections[.spanLengths]!)
                    replaceLittleEndian(nextLength + UInt16(length - shortenedLength), at: spanIndex + 1, in: &sections[.spanLengths]!)
                    return
                }
                spanStart += length
                spanIndex += 1
            }
        }, isCheckedByTheCodableDecoderToo: true),
        Damage(testDescription: "span columns of different lengths", apply: { sections in
            sections[.spanTypeCodes]!.removeFirst()
        }, isCheckedByTheCodableDecoderToo: true),
        Damage(testDescription: "text that is not UTF-8", apply: { sections in
            sections[.text]![sections[.text]!.startIndex] = 0xFF
        }),
        Damage(testDescription: "a region that does not start on a span", apply: { sections in
            let offset = littleEndian(UInt32.self, at: 0, in: sections[.regions]!)
            replaceLittleEndian(offset + 1, at: 0, in: &sections[.regions]!)
        }),
        Damage(testDescription: "a region past the end of its text", apply: { sections in
            replaceLittleEndian(UInt32(100_000), at: 1, in: &sections[.regions]!)
        }),
        Damage(testDescription: "a region naming a condition that is not there", apply: { sections in
            replaceLittleEndian(UInt32(99), at: 2, in: &sections[.regions]!)
        }),
        Damage(testDescription: "entries in the wrong order", apply: { sections in
            let firstTextEnd = littleEndian(UInt32.self, at: entryEndIndex(entry: 0, column: 0), in: sections[.entries]!)
            let secondTextEnd = littleEndian(UInt32.self, at: entryEndIndex(entry: 1, column: 0), in: sections[.entries]!)
            replaceLittleEndian(secondTextEnd, at: entryEndIndex(entry: 0, column: 0), in: &sections[.entries]!)
            replaceLittleEndian(firstTextEnd, at: entryEndIndex(entry: 1, column: 0), in: &sections[.entries]!)
        }),
        Damage(testDescription: "an entry that runs past its column", apply: { sections in
            replaceLittleEndian(UInt32(1_000_000), at: entryEndIndex(entry: 2, column: 1), in: &sections[.entries]!)
        }),
        Damage(testDescription: "columns holding more than the entries take", apply: { sections in
            sections[.text]!.append(contentsOf: Array("tail".utf8))
        }),
        Damage(testDescription: "an empty option name", apply: { sections in
            sections[.conditions] = renamingFirstOption(in: sections[.conditions]!, to: "")
        }),
        Damage(testDescription: "an option name with a control character", apply: { sections in
            sections[.conditions] = renamingFirstOption(in: sections[.conditions]!, to: "test\u{1}comments")
        }),
        Damage(testDescription: "a nested range out of its text", apply: { sections in
            replaceLittleEndian(Int64(1_000_000), at: 1, in: &sections[.nestedDefinitionRanges]!)
        }),
        Damage(testDescription: "a nested range that ends before it starts", apply: { sections in
            replaceLittleEndian(Int64(0), at: 1, in: &sections[.nestedDefinitionRanges]!)
        }),
        Damage(testDescription: "a different number of objects", apply: { sections in
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            sections[.objects] = try! encoder.encode([RuntimeObject]())
        }),
        Damage(testDescription: "a section missing", apply: { sections in
            sections[.identifiers] = nil
        }),
        Damage(testDescription: "a member kind this build does not know", apply: { sections in
            sections[.memberAttributes]![sections[.memberAttributes]!.startIndex] = 0x7F
        }),
        Damage(testDescription: "member columns of different lengths", apply: { sections in
            sections[.memberLineNumbers]!.removeLast(4)
        }),
        Damage(testDescription: "an entry that runs past its members", apply: { sections in
            replaceLittleEndian(UInt32(1_000), at: entryEndIndex(entry: 2, column: 6), in: &sections[.entries]!)
        }),
        Damage(testDescription: "member names holding more than the members take", apply: { sections in
            sections[.memberNames]!.appendLengthPrefixed("extra")
        }),
    ]

    /// The conditions column with its first option name replaced: the
    /// first condition's first alternative's first requirement.
    private static func renamingFirstOption(in conditions: Data, to name: String) -> Data {
        var reader = RuntimeDerivedDataByteReader(conditions)
        _ = try! reader.readUInt32()
        _ = try! reader.readUInt32()
        let isEnabledOffset = reader.offset
        _ = try! reader.readUInt8()
        let nameOffset = reader.offset
        let oldName = try! reader.readLengthPrefixedString()
        var renamed = Data(conditions.prefix(isEnabledOffset + 1))
        renamed.appendLengthPrefixed(name)
        renamed.append(conditions.dropFirst(nameOffset + 4 + oldName.utf8.count))
        return renamed
    }

    @Test("Damaged columns read as an error, never as a corpus", arguments: damages)
    func damagedColumns(damage: Damage) throws {
        var sections = try Self.sections(of: Self.makeCorpus())
        damage.apply(&sections)
        #expect(throws: (any Swift.Error).self) {
            _ = try Self.readCorpus(from: sections)
        }
        guard damage.isCheckedByTheCodableDecoderToo else { return }
        // The first entry's text and spans, as `FrozenSemanticString`'s own
        // decoder would get them: it has to turn them down as well.
        let entries = sections[.entries]!
        let textEnd = Int(Self.littleEndian(UInt32.self, at: Self.entryEndIndex(entry: 0, column: 0), in: entries))
        let spanEnd = Int(Self.littleEndian(UInt32.self, at: Self.entryEndIndex(entry: 0, column: 1), in: entries))
        // A column that lost elements is that much shorter in the first entry.
        let missingTypeCodeCount = sections[.spanLengths]!.count / 2 - sections[.spanTypeCodes]!.count
        let json: [String: Any] = [
            "text": String(decoding: sections[.text]!.prefix(textEnd), as: UTF8.self),
            "spanLengths": (0 ..< spanEnd).map { Int(Self.littleEndian(UInt16.self, at: $0, in: sections[.spanLengths]!)) },
            "spanTypeCodes": sections[.spanTypeCodes]!.prefix(spanEnd - missingTypeCodeCount).map { Int($0) },
            "spanIdentifierIndices": (0 ..< spanEnd).map { Int(Self.littleEndian(UInt32.self, at: $0, in: sections[.spanIdentifierIndices]!)) },
            "identifierTable": ["_"],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Swift.Error).self, "FrozenSemanticString's decoder accepts what the snapshot rejects") {
            _ = try JSONDecoder().decode(FrozenSemanticString.self, from: data)
        }
    }

    @Test("The undamaged sample passes FrozenSemanticString's decoder too")
    func undamagedSamplePassesTheCodableDecoder() throws {
        let entry = Self.makeCorpus().entries[0]
        let data = try JSONEncoder().encode(entry.interface)
        #expect(try JSONDecoder().decode(FrozenSemanticString.self, from: data) == entry.interface)
    }
}
