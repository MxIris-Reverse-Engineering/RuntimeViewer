import Foundation
import RuntimeViewerCore

/// One instruction's reference.
public struct RuntimeCrossReference: Hashable, Codable, Sendable {
    /// The function the referencing instruction belongs to.
    public let referencingFunction: RuntimeFunctionReference
    /// The referencing instruction's unslid address, in the same image as
    /// ``referencingFunction``.
    public let instructionAddress: UInt64
    public let kind: RuntimeCrossReferenceKind
    public let target: RuntimeCrossReferenceTarget
    public let precision: RuntimeCrossReferencePrecision
    /// A retain or release, an outlined value operation, or another runtime
    /// helper.
    public let isRuntimeHelperCall: Bool

    public init(referencingFunction: RuntimeFunctionReference, instructionAddress: UInt64, kind: RuntimeCrossReferenceKind, target: RuntimeCrossReferenceTarget, precision: RuntimeCrossReferencePrecision, isRuntimeHelperCall: Bool) {
        self.referencingFunction = referencingFunction
        self.instructionAddress = instructionAddress
        self.kind = kind
        self.target = target
        self.precision = precision
        self.isRuntimeHelperCall = isRuntimeHelperCall
    }
}
