import Semantic

extension RuntimeObjectInterface {
    /// The interface of an object printed with comment marking on: the text with the marks taken
    /// out, which is exactly what printing without them gives, and the structure they said.
    init(object: RuntimeObject, markedInterfaceString: FrozenSemanticString, interfaceLanguage: RuntimeInterfaceLanguage? = nil) {
        let (text, annotations) = markedInterfaceString.separatingAnnotationRegions()
        self.init(object: object, interfaceString: text, commentStructure: RuntimeInterfaceCommentStructure(annotations), interfaceLanguage: interfaceLanguage)
    }
}
