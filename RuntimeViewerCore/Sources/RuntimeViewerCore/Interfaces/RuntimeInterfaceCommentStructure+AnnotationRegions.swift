import Semantic

extension RuntimeInterfaceCommentStructure {
    /// The structure that an annotated print's table describes: swift-semantic-string's regions and
    /// segments, with the printers' kinds and roles carried over by name. A segment outside every
    /// region says nothing about a comment and is left out.
    ///
    /// The regions MachOSwiftSection puts around the attached macros' attributes
    /// (`marksAttachedMacros`) share the table but are no comments: they are left out, and the
    /// comments numbered again without them.
    init(_ table: AnnotationRegionTable) {
        var commentIndexByRegionIndex: [Int: Int] = [:]
        var comments: [Comment] = []
        // The table lists a region after the region enclosing it, so the enclosing one is numbered first.
        for (regionIndex, region) in table.regions.enumerated() where !Self.isAttachedMacroRegionKind(region.kind.rawValue) {
            commentIndexByRegionIndex[regionIndex] = comments.count
            comments.append(Comment(
                kind: Kind(rawValue: region.kind.rawValue),
                utf8Range: Int(region.utf8Offset) ..< Int(region.utf8Offset) + Int(region.utf8Length),
                enclosingCommentIndex: region.enclosingRegionIndex.flatMap { commentIndexByRegionIndex[$0] }
            ))
        }
        let segments = table.segments.compactMap { segment -> Segment? in
            guard let regionIndex = segment.regionIndex, let commentIndex = commentIndexByRegionIndex[regionIndex] else {
                return nil
            }
            return Segment(
                role: Role(rawValue: segment.role.rawValue),
                utf8Range: Int(segment.utf8Offset) ..< Int(segment.utf8Offset) + Int(segment.utf8Length),
                commentIndex: commentIndex
            )
        }
        self.init(comments: comments, segments: segments)
    }

    /// Whether a region kind is one of MachOSwiftSection's attached-macro kinds, one per macro:
    /// `attachedMacro.Observation.Observable`.
    static func isAttachedMacroRegionKind(_ rawValue: String) -> Bool {
        rawValue.hasPrefix("attachedMacro.")
    }
}
