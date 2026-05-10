import Foundation

// MARK: - RuntimeSpecializationRequest

/// Public, Codable description of a generic-type specialization request.
///
/// Built by `RuntimeEngine.specializationRequest(for:)` from the upstream
/// `SwiftInterface.SpecializationRequest` and consumed by the UI layer; this
/// keeps the application/UI layer (and the RPC protocol) free of
/// `@_spi(Support) SwiftInterface` types so the public surface is independent
/// of MachOSwiftSection's evolution.
///
/// Only the fields the UI actually needs are surfaced — descriptors,
/// associated-type requirements, key-argument counts, etc. live inside the
/// engine and never cross the wire.
public struct RuntimeSpecializationRequest: Codable, Hashable, Sendable {
    /// Generic parameters in declaration order.
    public let parameters: [Parameter]

    public init(parameters: [Parameter]) {
        self.parameters = parameters
    }
}

extension RuntimeSpecializationRequest {
    public struct Parameter: Codable, Hashable, Sendable {
        /// Canonical parameter name (`A`, `B`, `A1`, …).
        public let name: String

        /// Pre-formatted constraint description such as
        /// `A : Hashable & Equatable` or `A : AnyObject`. Built engine-side
        /// so the UI does not need to walk upstream requirement cases.
        public let displayDescription: String

        /// Concrete types that satisfy every key-argument constraint on this
        /// parameter. Generic candidates are flagged via `isGeneric` and are
        /// rejected at selection time (nested specialization is not supported
        /// in v1).
        public let candidates: [Candidate]

        public init(name: String, displayDescription: String, candidates: [Candidate]) {
            self.name = name
            self.displayDescription = displayDescription
            self.candidates = candidates
        }
    }

    public struct Candidate: Codable, Hashable, Sendable {
        /// Stable identity used to round-trip a selection back to the
        /// originating upstream `SpecializationRequest.Candidate` on the engine
        /// that produced this request. Treat as opaque (currently the
        /// candidate's mangled type name).
        public let id: String

        /// Display-friendly type name (e.g. `Int`, `Array<Element>`).
        public let displayName: String

        /// Image path the candidate originated from. Combined with `id` to
        /// disambiguate same-named types defined in different images.
        public let imagePath: String

        /// True when the candidate's type descriptor is itself generic.
        /// Selecting such a candidate would require nested specialization,
        /// which is not yet supported; the picker UI shows these disabled.
        public let isGeneric: Bool

        public init(id: String, displayName: String, imagePath: String, isGeneric: Bool) {
            self.id = id
            self.displayName = displayName
            self.imagePath = imagePath
            self.isGeneric = isGeneric
        }
    }
}

// MARK: - RuntimeSpecializationSelection

/// User selection mapping each generic parameter to a chosen candidate.
///
/// Only the candidate-from-list shape is exposed here — richer
/// upstream argument kinds (`metatype` / `metadata` / `specialized`) stay
/// inside MachOSwiftSection because they cannot be Codable / sent over the
/// wire and are not part of the v1 user-driven flow.
public struct RuntimeSpecializationSelection: Codable, Hashable, Sendable {
    /// Parameter name → selected candidate.
    public var arguments: [String: RuntimeSpecializationRequest.Candidate]

    public init(arguments: [String: RuntimeSpecializationRequest.Candidate] = [:]) {
        self.arguments = arguments
    }

    public func hasArgument(for parameterName: String) -> Bool {
        arguments[parameterName] != nil
    }

    public subscript(_ parameterName: String) -> RuntimeSpecializationRequest.Candidate? {
        arguments[parameterName]
    }

    public mutating func setCandidate(
        _ candidate: RuntimeSpecializationRequest.Candidate,
        for parameterName: String
    ) {
        arguments[parameterName] = candidate
    }
}

// MARK: - RuntimeSpecializationValidation

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

