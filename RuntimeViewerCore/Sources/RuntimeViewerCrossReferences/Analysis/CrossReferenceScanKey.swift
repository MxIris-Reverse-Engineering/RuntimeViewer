import Foundation
import FoundationToolbox
import MachO
import RuntimeViewerCore
import CrossReferenceAnalysis

/// What a scan looked for: the key its findings are kept under.
enum CrossReferenceScanKey: Hashable, Sendable {
    /// The references filed under any of these keys: a callers query.
    case references(Set<CodeReferenceTable.Key>)
    /// The references to the class whose object lies at this location. Not
    /// the class's name: the macOS and the Mac Catalyst variant of a
    /// framework define classes of the same name.
    case objectiveCClass(CodeLocation)
    /// The references to the Swift type whose descriptor lies here.
    case swiftType(CodeLocation)
}
