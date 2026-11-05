public import Foundation
import Compression

/// One piece of derived data as it is read back: sections of bytes, each
/// checked and decompressed, out of a file whose header said it was the
/// piece expected.
///
/// The file (`.rvdd`, little-endian):
///
/// - The magic `RVDD`, the format version and the length of the header.
/// - The header: kind, variant, image path, system directory name and
///   producer digest, each a length-prefixed UTF-8 string. A read compares
///   each with what it expects, so a file put in the wrong place reads as
///   nothing stored.
/// - The section table: each section's identifier, compression, offset,
///   stored length, decoded length and checksum — the first eight bytes of
///   the SHA-256 of what is stored.
/// - The checksum of everything above it.
/// - The sections, each stored as it is or compressed with LZFSE.
///
/// The format keeps no compatibility across versions: data of another
/// producer is never read, and a version that is not this one reads as
/// nothing stored.
public struct RuntimeDerivedDataContainer: Sendable {
    public struct SectionIdentifier: Hashable, Sendable, RawRepresentable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }
    }

    public enum Compression: UInt8, Sendable {
        case none = 0
        case lzfse = 1
    }

    /// What a container says it is.
    public struct Header: Hashable, Sendable {
        public var kind: String
        public var variant: String
        public var imagePath: String
        public var systemDirectoryName: String
        public var producerDigest: String

        public init(kind: String, variant: String, imagePath: String, systemDirectoryName: String, producerDigest: String) {
            self.kind = kind
            self.variant = variant
            self.imagePath = imagePath
            self.systemDirectoryName = systemDirectoryName
            self.producerDigest = producerDigest
        }
    }

    /// The sections of a container about to be written, compressed as they
    /// are added.
    public struct Builder: Sendable {
        fileprivate struct Section: Sendable {
            let identifier: SectionIdentifier
            let compression: Compression
            let storedBytes: Data
            let decodedByteCount: Int
        }

        fileprivate private(set) var sections: [Section] = []

        public init() {}

        /// Adds `data` as the section `identifier`. A section that LZFSE
        /// does not make smaller is stored as it is.
        public mutating func append(_ data: Data, as identifier: SectionIdentifier, compression: Compression = .lzfse) {
            precondition(!sections.contains { $0.identifier == identifier }, "a container has one section of each identifier")
            if compression == .lzfse, let compressed = RuntimeDerivedDataContainer.compressed(data), compressed.count < data.count {
                sections.append(Section(identifier: identifier, compression: .lzfse, storedBytes: compressed, decodedByteCount: data.count))
            } else {
                sections.append(Section(identifier: identifier, compression: .none, storedBytes: data, decodedByteCount: data.count))
            }
        }

        /// What the sections take before compression.
        public var decodedByteCount: Int {
            sections.reduce(0) { $0 + $1.decodedByteCount }
        }
    }

    public enum Error: Swift.Error, Hashable, Sendable, CustomStringConvertible {
        case notAContainer
        case unsupportedFormatVersion(UInt32)
        case truncated
        case headerMismatch
        case damagedHeader
        case damagedSection(UInt32)
        case missingSection(UInt32)

        public var description: String {
            switch self {
            case .notAContainer: "not a derived data container"
            case .unsupportedFormatVersion(let version): "format version \(version) is not this build's"
            case .truncated: "the file ends early"
            case .headerMismatch: "the header names other data"
            case .damagedHeader: "the header fails its checksum"
            case .damagedSection(let identifier): "section \(identifier) is damaged"
            case .missingSection(let identifier): "section \(identifier) is missing"
            }
        }
    }

    static let magic = Data("RVDD".utf8)

    static let formatVersion: UInt32 = 1

    /// More than any kind needs, so a damaged count cannot make a read
    /// allocate a table of millions of entries.
    static let maximumSectionCount = 64

    /// The most a section may decode to — some thirty times what AppKit's
    /// corpus decodes to in all its sections. The decoded length comes from
    /// the file and sizes the buffer a section decodes into, so it is checked
    /// before anything is allocated: `Int.max` once overflowed that size and
    /// trapped. A section a writer made larger only fails to read back.
    static let maximumDecodedSectionByteCount = 1 << 30

    private let sectionsByIdentifier: [SectionIdentifier: Data]

    /// The decoded bytes of section `identifier`.
    public func section(_ identifier: SectionIdentifier) throws -> Data {
        guard let section = sectionsByIdentifier[identifier] else {
            throw Error.missingSection(identifier.rawValue)
        }
        return section
    }

    // MARK: - Writing

    /// The file `builder`'s sections make under `header`.
    static func encoded(_ builder: Builder, header: Header) -> Data {
        var head = Data()
        head.append(magic)
        head.appendLittleEndian(formatVersion)
        let headerByteCountOffset = head.count
        head.appendLittleEndian(UInt32(0))
        for string in [header.kind, header.variant, header.imagePath, header.systemDirectoryName, header.producerDigest] {
            head.appendLengthPrefixed(string)
        }
        head.appendLittleEndian(UInt32(builder.sections.count))
        let tableEntryByteCount = 4 + 1 + 8 + 8 + 8 + 8
        let headerByteCount = head.count + builder.sections.count * tableEntryByteCount
        var sectionOffset = UInt64(headerByteCount + 8)
        for section in builder.sections {
            head.appendLittleEndian(section.identifier.rawValue)
            head.append(section.compression.rawValue)
            head.appendLittleEndian(sectionOffset)
            head.appendLittleEndian(UInt64(section.storedBytes.count))
            head.appendLittleEndian(UInt64(section.decodedByteCount))
            head.appendLittleEndian(RuntimeDerivedDataDigest.checksum(of: section.storedBytes))
            sectionOffset += UInt64(section.storedBytes.count)
        }
        assert(head.count == headerByteCount)
        head.replaceSubrange(headerByteCountOffset ..< headerByteCountOffset + 4, with: withUnsafeBytes(of: UInt32(headerByteCount).littleEndian) { Data($0) })
        var file = head
        file.appendLittleEndian(RuntimeDerivedDataDigest.checksum(of: head))
        for section in builder.sections {
            file.append(section.storedBytes)
        }
        return file
    }

    // MARK: - Reading

    /// Checks `data` from end to end — header, table, checksums, decoded
    /// lengths — and decompresses every section, throwing at the first
    /// thing that is not as it should be. With `sectionIdentifiers`, only
    /// those sections are checked against their checksums and decompressed;
    /// the table still is in full, and asking another section of the
    /// container throws `missingSection`.
    init(decoding data: Data, expecting expectedHeader: Header, sections sectionIdentifiers: Set<SectionIdentifier>? = nil) throws {
        var reader = RuntimeDerivedDataByteReader(data)
        guard data.count >= Self.magic.count, data.prefix(Self.magic.count) == Self.magic else { throw Error.notAContainer }
        reader.offset = Self.magic.count
        let formatVersion = try reader.readUInt32()
        guard formatVersion == Self.formatVersion else { throw Error.unsupportedFormatVersion(formatVersion) }
        let headerByteCount = Int(try reader.readUInt32())
        guard headerByteCount >= reader.offset, headerByteCount <= data.count - 8 else { throw Error.truncated }
        let headerChecksumOffset = data.startIndex + headerByteCount
        let storedHeaderChecksum = data[headerChecksumOffset ..< headerChecksumOffset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard RuntimeDerivedDataDigest.checksum(of: data.prefix(headerByteCount)) == UInt64(littleEndian: storedHeaderChecksum) else {
            throw Error.damagedHeader
        }
        reader.limit = headerByteCount
        let header = Header(
            kind: try reader.readLengthPrefixedString(),
            variant: try reader.readLengthPrefixedString(),
            imagePath: try reader.readLengthPrefixedString(),
            systemDirectoryName: try reader.readLengthPrefixedString(),
            producerDigest: try reader.readLengthPrefixedString()
        )
        guard header == expectedHeader else { throw Error.headerMismatch }
        let sectionCount = Int(try reader.readUInt32())
        guard sectionCount <= Self.maximumSectionCount else { throw Error.damagedHeader }

        var sectionsByIdentifier: [SectionIdentifier: Data] = [:]
        var tableIdentifiers: Set<SectionIdentifier> = []
        for _ in 0 ..< sectionCount {
            let identifier = SectionIdentifier(rawValue: try reader.readUInt32())
            guard let compression = Compression(rawValue: try reader.readUInt8()) else { throw Error.damagedSection(identifier.rawValue) }
            let offset = try reader.readUInt64()
            let storedByteCount = try reader.readUInt64()
            let decodedByteCount = try reader.readUInt64()
            let checksum = try reader.readUInt64()
            guard tableIdentifiers.insert(identifier).inserted,
                  offset >= UInt64(headerByteCount + 8),
                  storedByteCount <= UInt64(data.count),
                  offset <= UInt64(data.count) - storedByteCount,
                  decodedByteCount <= UInt64(Self.maximumDecodedSectionByteCount)
            else { throw Error.damagedSection(identifier.rawValue) }
            // A section not asked for is passed over once its table entry
            // is read and checked: the rest of the table follows it.
            if let sectionIdentifiers, !sectionIdentifiers.contains(identifier) {
                continue
            }
            let storedBytes = data[(data.startIndex + Int(offset)) ..< (data.startIndex + Int(offset + storedByteCount))]
            guard RuntimeDerivedDataDigest.checksum(of: storedBytes) == checksum else { throw Error.damagedSection(identifier.rawValue) }
            switch compression {
            case .none:
                guard storedByteCount == decodedByteCount else { throw Error.damagedSection(identifier.rawValue) }
                sectionsByIdentifier[identifier] = Data(storedBytes)
            case .lzfse:
                guard let decoded = Self.decompressed(storedBytes, decodedByteCount: Int(decodedByteCount)) else {
                    throw Error.damagedSection(identifier.rawValue)
                }
                sectionsByIdentifier[identifier] = decoded
            }
        }
        guard reader.offset == headerByteCount else { throw Error.damagedHeader }
        self.sectionsByIdentifier = sectionsByIdentifier
    }

    // MARK: - Compression

    /// `data` in LZFSE, or `nil` when the encoder gives up.
    fileprivate static func compressed(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // An incompressible input comes out a little larger than it went in.
        let capacity = data.count + data.count / 8 + 4096
        var compressed = Data(count: capacity)
        let compressedByteCount = compressed.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard compressedByteCount > 0 else { return nil }
        compressed.count = compressedByteCount
        return compressed
    }

    /// `data` decoded from LZFSE when it decodes to exactly
    /// `decodedByteCount` bytes, `nil` otherwise. The buffer is one byte
    /// larger than that, so a section that would decode to more is caught
    /// without decoding it whole.
    static func decompressed(_ data: Data, decodedByteCount: Int) -> Data? {
        guard decodedByteCount > 0, !data.isEmpty else { return decodedByteCount == 0 && data.isEmpty ? Data() : nil }
        var decoded = Data(count: decodedByteCount + 1)
        let decodedCount = decoded.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, decodedByteCount + 1,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == decodedByteCount else { return nil }
        decoded.count = decodedByteCount
        return decoded
    }
}
