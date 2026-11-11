import Foundation
@testable import RuntimeViewerCore
import Semantic
import Testing

/// MachOSwiftSection marks the attached macros' attributes with annotation regions of their own
/// kind, in the same table as the comments (`marksAttachedMacros`). They are no comments: the
/// comment structure leaves them out and numbers the comments without them, or the SourceEditor
/// pane would draw `@Observation.Observable` as a comment tag.
@Suite("RuntimeInterfaceCommentStructure and attached macro regions")
struct RuntimeInterfaceCommentStructureMacroRegionTests {
    private static let attachedMacroKind = AnnotationRegion.Kind("attachedMacro.Observation.Observable")

    @Test func attachedMacroRegionsAreNotComments() {
        let marked = SemanticString {
            AnnotationRegion(Self.attachedMacroKind) {
                Standard("@Observation.Observable")
            }
            Standard("\n")
            AnnotationRegion(.note) {
                AnnotationSegment(AnnotationSegment.Role("marker")) {
                    Standard("// ")
                }
                AnnotationSegment(AnnotationSegment.Role("text")) {
                    Standard("a note")
                }
            }
        }

        let (text, table) = marked.frozen().separatingAnnotationRegions()
        #expect(table.regions.count == 2)
        let structure = RuntimeInterfaceCommentStructure(table)

        #expect(structure.comments.count == 1)
        let comment = structure.comments.first
        #expect(comment?.kind.rawValue == "note")
        let noteStart = "@Observation.Observable\n".utf8.count
        #expect(comment?.utf8Range == noteStart ..< text.string.utf8.count)
        #expect(structure.segments.count == 2)
        #expect(structure.segments.allSatisfy { $0.commentIndex == 0 })
    }

    @Test func aStructureWithoutMacroRegionsIsNumberedAsBefore() {
        let marked = SemanticString {
            AnnotationRegion(.note) {
                Standard("// first")
            }
            Standard("\n")
            AnnotationRegion(.note) {
                Standard("// second")
            }
        }

        let (_, table) = marked.frozen().separatingAnnotationRegions()
        let structure = RuntimeInterfaceCommentStructure(table)
        #expect(structure.comments.count == 2)
        #expect(structure.comments.map(\.enclosingCommentIndex) == [nil, nil])
    }

    @Test func onlyTheAttachedMacroKindsAreRecognized() {
        #expect(RuntimeInterfaceCommentStructure.isAttachedMacroRegionKind("attachedMacro.Observation.Observable"))
        #expect(!RuntimeInterfaceCommentStructure.isAttachedMacroRegionKind("note"))
        #expect(!RuntimeInterfaceCommentStructure.isAttachedMacroRegionKind("memberAddress"))
    }
}
