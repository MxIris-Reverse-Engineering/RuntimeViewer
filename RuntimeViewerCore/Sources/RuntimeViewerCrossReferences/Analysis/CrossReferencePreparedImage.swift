import Foundation
import FoundationToolbox
import MachO
import RuntimeViewerCore
import CrossReferenceAnalysis

/// An image's prepared cross references, as the session keeps them: its
/// index, and the memory of what the analyzer keeps to name what the index
/// answers with — the image's function table and the names read for it —
/// which the byte limit counts along with the index: about two thirds again
/// for AppKit.
struct CrossReferencePreparedImage: Sendable {
    let index: CodeReferenceIndex
    let namingByteCount: Int

    var byteCount: Int {
        index.approximateByteCount + namingByteCount
    }
}
