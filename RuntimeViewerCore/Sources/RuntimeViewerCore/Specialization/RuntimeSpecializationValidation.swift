import Foundation
import SwiftStdlibToolbox

/// Public, Codable mirror of MachOSwiftSection's `SpecializationValidation`.
///
/// Returned by `RuntimeEngine.runtimePreflight(for:with:)` so the UI can
/// surface protocol / layout / base-class / same-type mismatches *before*
/// invoking `specialize(_:with:)`. Like `RuntimeSpecializationRequest`, the
/// shape stays free of `@_spi(Support) SwiftInterface` types so the wire
/// protocol is independent of the upstream package.
public struct RuntimeSpecializationValidation: Codable, Hashable, Sendable {
    public let isValid: Bool
    public let errors: [Error]
    public let warnings: [Warning]

    public init(isValid: Bool, errors: [Error] = [], warnings: [Warning] = []) {
        self.isValid = isValid
        self.errors = errors
        self.warnings = warnings
    }

    public static let valid = RuntimeSpecializationValidation(isValid: true)
}

extension RuntimeSpecializationValidation {
    public enum Error: Codable, Hashable, Sendable, CustomStringConvertible {
        case missingArgument(parameterName: String)
        case protocolRequirementNotSatisfied(parameterName: String, protocolName: String, actualType: String)
        case layoutRequirementNotSatisfied(parameterName: String, expectedLayout: String, actualType: String)
        case baseClassRequirementNotSatisfied(parameterName: String, expectedBaseClass: String, actualType: String)
        case sameTypeRequirementNotSatisfied(parameterName: String, expectedType: String, actualType: String)
        case metadataResolutionFailed(parameterName: String, reason: String)
        case protocolDescriptorResolutionFailed(parameterName: String, protocolName: String, reason: String)

        public var description: String {
            switch self {
            case .missingArgument(let parameterName):
                return "Missing argument for parameter '\(parameterName)'"
            case .protocolRequirementNotSatisfied(let parameterName, let protocolName, let actualType):
                return "Type '\(actualType)' for parameter '\(parameterName)' does not conform to protocol '\(protocolName)'"
            case .layoutRequirementNotSatisfied(let parameterName, let expectedLayout, let actualType):
                return "Type '\(actualType)' for parameter '\(parameterName)' does not satisfy layout requirement '\(expectedLayout)'"
            case .baseClassRequirementNotSatisfied(let parameterName, let expectedBaseClass, let actualType):
                return "Type '\(actualType)' for parameter '\(parameterName)' does not inherit from required base class '\(expectedBaseClass)'"
            case .sameTypeRequirementNotSatisfied(let parameterName, let expectedType, let actualType):
                return "Type '\(actualType)' for parameter '\(parameterName)' does not equal required same-type '\(expectedType)'"
            case .metadataResolutionFailed(let parameterName, let reason):
                return "Could not resolve metadata for parameter '\(parameterName)': \(reason)"
            case .protocolDescriptorResolutionFailed(let parameterName, let protocolName, let reason):
                return "Could not construct protocol descriptor for '\(protocolName)' (parameter '\(parameterName)'): \(reason)"
            }
        }
    }

    public enum Warning: Codable, Hashable, Sendable, CustomStringConvertible {
        case extraArgument(parameterName: String)
        case associatedTypePathInSelection(path: String)
        case protocolNotInIndexer(parameterName: String, protocolName: String)
        case conformanceCheckFailed(parameterName: String, protocolName: String, reason: String)
        case baseClassRequirementResolutionFailed(parameterName: String, reason: String)
        case sameTypeRequirementResolutionSkipped(parameterName: String, reason: String)

        public var description: String {
            switch self {
            case .extraArgument(let parameterName):
                return "Extra argument '\(parameterName)' is not needed for this specialization"
            case .associatedTypePathInSelection(let path):
                return "Selection key '\(path)' refers to an associated-type path; associated types are derived and cannot be set directly"
            case .protocolNotInIndexer(let parameterName, let protocolName):
                return "Cannot validate conformance of parameter '\(parameterName)' to '\(protocolName)': protocol descriptor not found in indexer"
            case .conformanceCheckFailed(let parameterName, let protocolName, let reason):
                return "Conformance check for parameter '\(parameterName)' against protocol '\(protocolName)' failed to run: \(reason)"
            case .baseClassRequirementResolutionFailed(let parameterName, let reason):
                return "Could not resolve required base class for parameter '\(parameterName)'; preflight skipped the inheritance check: \(reason)"
            case .sameTypeRequirementResolutionSkipped(let parameterName, let reason):
                return "Could not resolve same-type requirement for parameter '\(parameterName)'; preflight skipped the equality check: \(reason)"
            }
        }
    }
}
