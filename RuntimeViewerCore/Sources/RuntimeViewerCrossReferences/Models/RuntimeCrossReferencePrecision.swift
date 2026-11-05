import Foundation
import RuntimeViewerCore

public enum RuntimeCrossReferencePrecision: String, Hashable, Codable, Sendable {
    /// The instruction names its target.
    case exact
    /// An Objective-C send whose receiver's class is not known: every send of
    /// the selector matches.
    case matchedBySelector
    /// One of several targets an indirect call may reach.
    case candidate
}
