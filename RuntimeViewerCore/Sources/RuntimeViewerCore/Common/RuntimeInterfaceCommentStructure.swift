import Foundation

/// What the generator said about each comment of an interface: what the comment is, the role of
/// every run of text inside it, and which comments sit inside which — so that a viewer can present
/// comments without reading their text.
///
/// The printers mark this up as they print (MachOSwiftSection's and MachOObjCSection's
/// `marksCommentStructure`); the engine separates it from the text and sends it next to
/// `RuntimeObjectInterface.interfaceString`, whose text it describes. **Offsets count UTF-8 bytes
/// of that text.** Kinds and roles are the producers' strings; a viewer treats a kind it does not
/// know as ``Kind/note``.
public struct RuntimeInterfaceCommentStructure: Sendable, Hashable {
    /// What a comment is, as the printer that wrote it names it.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        // Swift, from MachOSwiftSection.
        public static let memberAddress = Kind(rawValue: "memberAddress")
        public static let vtableOffset = Kind(rawValue: "vtableOffset")
        public static let pwtOffset = Kind(rawValue: "pwtOffset")
        /// A field's offset; when the field's layout is expanded, the comment encloses the whole
        /// tree of ``fieldLayoutNode``s below it.
        public static let fieldOffset = Kind(rawValue: "fieldOffset")
        public static let fieldOffsetUnknown = Kind(rawValue: "fieldOffsetUnknown")
        /// One row of an expanded field layout. Encloses its own line and every descendant's.
        public static let fieldLayoutNode = Kind(rawValue: "fieldLayoutNode")
        public static let typeLayout = Kind(rawValue: "typeLayout")
        public static let typeLayoutElement = Kind(rawValue: "typeLayoutElement")
        public static let enumLayoutSummary = Kind(rawValue: "enumLayoutSummary")
        /// One case's layout block: the `/* Enum Layout */` line and every comment line of the
        /// case, enclosing the ``enumLayoutCaseHeader`` and the lines after it.
        public static let enumLayoutCase = Kind(rawValue: "enumLayoutCase")
        public static let enumLayoutCaseHeader = Kind(rawValue: "enumLayoutCaseHeader")
        public static let enumLayoutCaseEncoding = Kind(rawValue: "enumLayoutCaseEncoding")
        public static let enumLayoutCaseNote = Kind(rawValue: "enumLayoutCaseNote")
        public static let enumLayoutCaseFixedBytes = Kind(rawValue: "enumLayoutCaseFixedBytes")
        public static let enumLayoutCaseByte = Kind(rawValue: "enumLayoutCaseByte")
        public static let exportStatus = Kind(rawValue: "exportStatus")
        public static let protocolExtensionDefault = Kind(rawValue: "protocolExtensionDefault")
        public static let privateDeclarationSource = Kind(rawValue: "privateDeclarationSource")
        public static let conditionalWitness = Kind(rawValue: "conditionalWitness")
        public static let conditionalWitnessBranch = Kind(rawValue: "conditionalWitnessBranch")
        public static let strippedSymbolicRequirement = Kind(rawValue: "strippedSymbolicRequirement")

        // Objective-C, from MachOObjCSection.
        public static let impAddress = Kind(rawValue: "impAddress")
        public static let ivarOffset = Kind(rawValue: "ivarOffset")
        public static let ivarOffsetUnknown = Kind(rawValue: "ivarOffsetUnknown")
        public static let propertySynthesis = Kind(rawValue: "propertySynthesis")
        public static let propertyDynamic = Kind(rawValue: "propertyDynamic")
        public static let typeNote = Kind(rawValue: "typeNote")

        /// A sentence of explanation, and every kind a viewer does not know.
        public static let note = Kind(rawValue: "note")
    }

    /// What a run of text inside a comment is.
    public struct Role: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// `// `, `/* `, ` */`, with the alignment spaces of a continuation line.
        public static let marker = Role(rawValue: "marker")
        /// What a fact is: `Address`, `VTable offset`, `getter IMP`.
        public static let label = Role(rawValue: "label")
        /// What narrows a label: the `getter` in `Address (getter)`.
        public static let qualifier = Role(rawValue: "qualifier")
        /// Punctuation between the other runs: `: `, ` (`, `, `.
        public static let separator = Role(rawValue: "separator")
        /// The name of one of several facts: `size`, `stride`.
        public static let key = Role(rawValue: "key")
        /// A fact: `0x135DC`, `16`.
        public static let value = Role(rawValue: "value")
        /// A field's or a case's name.
        public static let name = Role(rawValue: "name")
        /// A type's name.
        public static let type = Role(rawValue: "type")
        /// The `│   ├── ` in front of a field layout row.
        public static let treePrefix = Role(rawValue: "treePrefix")
        /// Prose.
        public static let text = Role(rawValue: "text")
    }

    public struct Comment: Sendable, Hashable {
        public let kind: Kind

        public let utf8Range: Range<Int>

        /// The index in ``RuntimeInterfaceCommentStructure/comments`` of the comment directly
        /// enclosing this one; nil for a comment directly in the text.
        public let enclosingCommentIndex: Int?

        public init(kind: Kind, utf8Range: Range<Int>, enclosingCommentIndex: Int?) {
            self.kind = kind
            self.utf8Range = utf8Range
            self.enclosingCommentIndex = enclosingCommentIndex
        }
    }

    public struct Segment: Sendable, Hashable {
        public let role: Role

        public let utf8Range: Range<Int>

        /// The index of the innermost comment the segment belongs to.
        public let commentIndex: Int

        public init(role: Role, utf8Range: Range<Int>, commentIndex: Int) {
            self.role = role
            self.utf8Range = utf8Range
            self.commentIndex = commentIndex
        }
    }

    /// In text order, each after the comment enclosing it.
    public let comments: [Comment]

    /// In text order.
    public let segments: [Segment]

    public init(comments: [Comment], segments: [Segment]) {
        self.comments = comments
        self.segments = segments
    }

    public var isEmpty: Bool { comments.isEmpty }
}

// MARK: - Codable

/// Columnar, like `FrozenSemanticString`: a large interface carries tens of thousands of segments,
/// and an object with keys per segment would outweigh the text it describes. Kinds and roles are
/// interned into tables and referred to by index.
extension RuntimeInterfaceCommentStructure: Codable {
    private enum CodingKeys: String, CodingKey {
        case kindTable
        case commentKindIndices
        case commentOffsets
        case commentLengths
        case commentEnclosingIndices
        case roleTable
        case segmentRoleIndices
        case segmentOffsets
        case segmentLengths
        case segmentCommentIndices
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        var kindTable: [String] = []
        var kindIndexByRawValue: [String: Int] = [:]
        var commentKindIndices: [Int] = []
        commentKindIndices.reserveCapacity(comments.count)
        for comment in comments {
            if let index = kindIndexByRawValue[comment.kind.rawValue] {
                commentKindIndices.append(index)
            } else {
                kindIndexByRawValue[comment.kind.rawValue] = kindTable.count
                commentKindIndices.append(kindTable.count)
                kindTable.append(comment.kind.rawValue)
            }
        }
        try container.encode(kindTable, forKey: .kindTable)
        try container.encode(commentKindIndices, forKey: .commentKindIndices)
        try container.encode(comments.map(\.utf8Range.lowerBound), forKey: .commentOffsets)
        try container.encode(comments.map(\.utf8Range.count), forKey: .commentLengths)
        try container.encode(comments.map { $0.enclosingCommentIndex ?? -1 }, forKey: .commentEnclosingIndices)

        var roleTable: [String] = []
        var roleIndexByRawValue: [String: Int] = [:]
        var segmentRoleIndices: [Int] = []
        segmentRoleIndices.reserveCapacity(segments.count)
        for segment in segments {
            if let index = roleIndexByRawValue[segment.role.rawValue] {
                segmentRoleIndices.append(index)
            } else {
                roleIndexByRawValue[segment.role.rawValue] = roleTable.count
                segmentRoleIndices.append(roleTable.count)
                roleTable.append(segment.role.rawValue)
            }
        }
        try container.encode(roleTable, forKey: .roleTable)
        try container.encode(segmentRoleIndices, forKey: .segmentRoleIndices)
        try container.encode(segments.map(\.utf8Range.lowerBound), forKey: .segmentOffsets)
        try container.encode(segments.map(\.utf8Range.count), forKey: .segmentLengths)
        try container.encode(segments.map(\.commentIndex), forKey: .segmentCommentIndices)
    }

    /// Checks what a reader would otherwise trap on — columns of one table agree in length, every
    /// index points into its table, no range is negative — and nothing about the text, which this
    /// value never sees: a consumer still checks each range against the text it was sent with.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let kindTable = try container.decode([String].self, forKey: .kindTable)
        let commentKindIndices = try container.decode([Int].self, forKey: .commentKindIndices)
        let commentOffsets = try container.decode([Int].self, forKey: .commentOffsets)
        let commentLengths = try container.decode([Int].self, forKey: .commentLengths)
        let commentEnclosingIndices = try container.decode([Int].self, forKey: .commentEnclosingIndices)
        guard commentOffsets.count == commentKindIndices.count,
              commentLengths.count == commentKindIndices.count,
              commentEnclosingIndices.count == commentKindIndices.count
        else {
            throw DecodingError.dataCorruptedError(forKey: .commentOffsets, in: container, debugDescription: "comment columns disagree in length")
        }
        var comments: [Comment] = []
        comments.reserveCapacity(commentKindIndices.count)
        for index in commentKindIndices.indices {
            let enclosingIndex = commentEnclosingIndices[index]
            guard kindTable.indices.contains(commentKindIndices[index]),
                  commentOffsets[index] >= 0,
                  commentLengths[index] >= 0,
                  commentLengths[index] <= Int.max - commentOffsets[index],
                  enclosingIndex == -1 || (0 ..< index).contains(enclosingIndex)
            else {
                throw DecodingError.dataCorruptedError(forKey: .commentKindIndices, in: container, debugDescription: "comment \(index) is out of range")
            }
            comments.append(Comment(
                kind: Kind(rawValue: kindTable[commentKindIndices[index]]),
                utf8Range: commentOffsets[index] ..< commentOffsets[index] + commentLengths[index],
                enclosingCommentIndex: enclosingIndex == -1 ? nil : enclosingIndex
            ))
        }

        let roleTable = try container.decode([String].self, forKey: .roleTable)
        let segmentRoleIndices = try container.decode([Int].self, forKey: .segmentRoleIndices)
        let segmentOffsets = try container.decode([Int].self, forKey: .segmentOffsets)
        let segmentLengths = try container.decode([Int].self, forKey: .segmentLengths)
        let segmentCommentIndices = try container.decode([Int].self, forKey: .segmentCommentIndices)
        guard segmentOffsets.count == segmentRoleIndices.count,
              segmentLengths.count == segmentRoleIndices.count,
              segmentCommentIndices.count == segmentRoleIndices.count
        else {
            throw DecodingError.dataCorruptedError(forKey: .segmentOffsets, in: container, debugDescription: "segment columns disagree in length")
        }
        var segments: [Segment] = []
        segments.reserveCapacity(segmentRoleIndices.count)
        for index in segmentRoleIndices.indices {
            guard roleTable.indices.contains(segmentRoleIndices[index]),
                  segmentOffsets[index] >= 0,
                  segmentLengths[index] >= 0,
                  segmentLengths[index] <= Int.max - segmentOffsets[index],
                  comments.indices.contains(segmentCommentIndices[index])
            else {
                throw DecodingError.dataCorruptedError(forKey: .segmentRoleIndices, in: container, debugDescription: "segment \(index) is out of range")
            }
            segments.append(Segment(
                role: Role(rawValue: roleTable[segmentRoleIndices[index]]),
                utf8Range: segmentOffsets[index] ..< segmentOffsets[index] + segmentLengths[index],
                commentIndex: segmentCommentIndices[index]
            ))
        }

        self.init(comments: comments, segments: segments)
    }
}
