import Foundation
import Testing
@testable import RuntimeViewerCore

/// The container file: what goes in comes back out, and anything else —
/// a short file, a flipped bit, a header naming other data — is an error,
/// never a trap.
@Suite("RuntimeDerivedDataContainer")
struct RuntimeDerivedDataContainerTests {
    private static let header = RuntimeDerivedDataContainer.Header(
        kind: "InterfaceCorpus",
        variant: "0123456789abcdef-ByCategory",
        imagePath: "/usr/lib/libobjc.A.dylib",
        systemDirectoryName: DerivedDataTestIdentities.system.directoryName,
        producerDigest: DerivedDataTestIdentities.producer.digest
    )

    private static let textSection = RuntimeDerivedDataContainer.SectionIdentifier(rawValue: 1)
    private static let rawSection = RuntimeDerivedDataContainer.SectionIdentifier(rawValue: 2)
    private static let emptySection = RuntimeDerivedDataContainer.SectionIdentifier(rawValue: 3)

    private static let compressibleText = Data(String(repeating: "@interface NSObject (Category)\n- (void)method;\n@end\n", count: 400).utf8)
    private static let incompressibleBytes = Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: ($0 &* 2654435761) >> 13) })

    private static func encodedFile() -> Data {
        var builder = RuntimeDerivedDataContainer.Builder()
        builder.append(compressibleText, as: textSection)
        builder.append(incompressibleBytes, as: rawSection, compression: .none)
        builder.append(Data(), as: emptySection)
        return RuntimeDerivedDataContainer.encoded(builder, header: header)
    }

    /// `encodedFile()` with the text section's decoded length replaced by
    /// `decodedByteCount` and the header checksum made right again — what a
    /// writer with a bug, or a crafted file, would leave.
    private static func encodedFile(claimingDecodedByteCount decodedByteCount: UInt64) -> Data {
        var file = encodedFile()
        let headerByteCount = Int(UInt32(littleEndian: file[8 ..< 12].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        // The magic, the format version and the header's length; the five
        // length-prefixed strings; the section count. The text section's
        // entry comes first: identifier, compression, offset, stored length,
        // then the decoded length.
        var decodedByteCountOffset = 12
        for string in [header.kind, header.variant, header.imagePath, header.systemDirectoryName, header.producerDigest] {
            decodedByteCountOffset += 4 + string.utf8.count
        }
        decodedByteCountOffset += 4 + 4 + 1 + 8 + 8
        withUnsafeBytes(of: decodedByteCount.littleEndian) { file.replaceSubrange(decodedByteCountOffset ..< decodedByteCountOffset + 8, with: $0) }
        let headerChecksum = RuntimeDerivedDataDigest.checksum(of: file.prefix(headerByteCount))
        withUnsafeBytes(of: headerChecksum.littleEndian) { file.replaceSubrange(headerByteCount ..< headerByteCount + 8, with: $0) }
        return file
    }

    @Test("Sections come back as they went in, compressed or not")
    func roundTrip() throws {
        let file = Self.encodedFile()
        #expect(file.count < Self.compressibleText.count, "the text section is stored compressed")
        let container = try RuntimeDerivedDataContainer(decoding: file, expecting: Self.header)
        #expect(try container.section(Self.textSection) == Self.compressibleText)
        #expect(try container.section(Self.rawSection) == Self.incompressibleBytes)
        #expect(try container.section(Self.emptySection) == Data())
        #expect(throws: RuntimeDerivedDataContainer.Error.missingSection(9)) {
            try container.section(.init(rawValue: 9))
        }
    }

    @Test("A slice of a larger buffer decodes like the bytes on their own")
    func decodingFromASlice() throws {
        let padded = Data([0xAA, 0xBB, 0xCC]) + Self.encodedFile()
        let container = try RuntimeDerivedDataContainer(decoding: padded.dropFirst(3), expecting: Self.header)
        #expect(try container.section(Self.textSection) == Self.compressibleText)
    }

    @Test("A header naming other data reads as an error", arguments: [
        \RuntimeDerivedDataContainer.Header.kind,
        \.variant,
        \.imagePath,
        \.systemDirectoryName,
        \.producerDigest,
    ])
    func headerMismatch(field: WritableKeyPath<RuntimeDerivedDataContainer.Header, String>) {
        var expectedHeader = Self.header
        expectedHeader[keyPath: field] += "-other"
        #expect(throws: RuntimeDerivedDataContainer.Error.headerMismatch) {
            _ = try RuntimeDerivedDataContainer(decoding: Self.encodedFile(), expecting: expectedHeader)
        }
    }

    @Test("Every truncation of the file is an error")
    func truncation() {
        let file = Self.encodedFile()
        for length in stride(from: 0, to: file.count, by: max(1, file.count / 97)) {
            #expect(throws: (any Error).self) {
                _ = try RuntimeDerivedDataContainer(decoding: file.prefix(length), expecting: Self.header)
            }
        }
    }

    @Test("A flipped byte anywhere in the file is an error")
    func flippedBytes() {
        let file = Self.encodedFile()
        for offset in stride(from: 0, to: file.count, by: max(1, file.count / 211)) {
            var damaged = file
            damaged[offset] ^= 0x5A
            #expect(throws: (any Error).self, "byte \(offset)") {
                _ = try RuntimeDerivedDataContainer(decoding: damaged, expecting: Self.header)
            }
        }
    }

    @Test("Another format version is not read")
    func otherFormatVersion() {
        var file = Self.encodedFile()
        file[4] = 0x7F
        #expect(throws: RuntimeDerivedDataContainer.Error.unsupportedFormatVersion(0x7F)) {
            _ = try RuntimeDerivedDataContainer(decoding: file, expecting: Self.header)
        }
    }

    @Test("A file that is not a container is said to be one of none")
    func notAContainer() {
        #expect(throws: RuntimeDerivedDataContainer.Error.notAContainer) {
            _ = try RuntimeDerivedDataContainer(decoding: Data("plain text, nothing more".utf8), expecting: Self.header)
        }
    }

    /// The decoded length is the file's word, checked before a buffer is
    /// allocated for it: `Int.max` used to overflow the buffer's size and
    /// trap, a service reading the file going down with it (PR126.6).
    @Test("A decoded length larger than any section is an error, not a trap", arguments: [UInt64(Int.max), 1 << 40, (1 << 30) + 1])
    func oversizedDecodedLength(decodedByteCount: UInt64) {
        #expect(throws: RuntimeDerivedDataContainer.Error.damagedSection(Self.textSection.rawValue)) {
            _ = try RuntimeDerivedDataContainer(decoding: Self.encodedFile(claimingDecodedByteCount: decodedByteCount), expecting: Self.header)
        }
    }

    @Test("LZFSE bytes decode only to the length recorded for them")
    func decodedLengthMismatch() throws {
        let text = Self.compressibleText
        let compressed = try (text as NSData).compressed(using: .lzfse) as Data
        #expect(RuntimeDerivedDataContainer.decompressed(compressed, decodedByteCount: text.count) == text)
        #expect(RuntimeDerivedDataContainer.decompressed(compressed, decodedByteCount: text.count - 1) == nil)
        #expect(RuntimeDerivedDataContainer.decompressed(compressed, decodedByteCount: text.count + 1) == nil)
        #expect(RuntimeDerivedDataContainer.decompressed(Data([1, 2, 3, 4]), decodedByteCount: 16) == nil)
    }
}
