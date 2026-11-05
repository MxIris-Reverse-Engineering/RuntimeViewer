import Semantic

extension RuntimeInterfaceCommentStructure {
    /// The structure that an annotated print's table describes: swift-semantic-string's regions and
    /// segments, with the printers' kinds and roles carried over by name. A segment outside every
    /// region says nothing about a comment and is left out.
    init(_ table: AnnotationRegionTable) {
        let comments = table.regions.map { region in
            Comment(
                kind: Kind(rawValue: region.kind.rawValue),
                utf8Range: Int(region.utf8Offset) ..< Int(region.utf8Offset) + Int(region.utf8Length),
                enclosingCommentIndex: region.enclosingRegionIndex
            )
        }
        let segments = table.segments.compactMap { segment -> Segment? in
            guard let regionIndex = segment.regionIndex else { return nil }
            return Segment(
                role: Role(rawValue: segment.role.rawValue),
                utf8Range: Int(segment.utf8Offset) ..< Int(segment.utf8Offset) + Int(segment.utf8Length),
                commentIndex: regionIndex
            )
        }
        self.init(comments: comments, segments: segments)
    }
}

extension RuntimeObjectInterface {
    /// The interface of an object printed with comment marking on: the text with the marks taken
    /// out, which is exactly what printing without them gives, and the structure they said.
    init(object: RuntimeObject, markedInterfaceString: FrozenSemanticString) {
        let (text, annotations) = markedInterfaceString.separatingAnnotationRegions()
        self.init(object: object, interfaceString: text, commentStructure: RuntimeInterfaceCommentStructure(annotations))
    }
}
