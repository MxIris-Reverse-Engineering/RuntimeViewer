import Foundation
import SwiftStdlibToolbox

/// User selection mapping each generic parameter to an argument.
///
/// An argument is either a concrete candidate (`.candidate`) or a recursive
/// nested specialization (`.boundGeneric`). Richer upstream argument kinds
/// (`metatype` / `metadata` / `specialized`) stay inside MachOSwiftSection
/// because they cannot be Codable / sent over the wire and are not part of
/// the v1 user-driven flow.
public struct RuntimeSpecializationSelection: Codable, Hashable, Sendable {
    /// Parameter name → selected argument.
    public var arguments: [String: Argument]

    public init(arguments: [String: Argument] = [:]) {
        self.arguments = arguments
    }

    public func hasArgument(for parameterName: String) -> Bool {
        arguments[parameterName] != nil
    }

    public subscript(_ parameterName: String) -> Argument? {
        arguments[parameterName]
    }

    public mutating func setArgument(
        _ argument: Argument,
        for parameterName: String,
    ) {
        arguments[parameterName] = argument
    }

    /// A user-driven argument for a single generic parameter.
    ///
    /// `.candidate` binds the parameter to a concrete leaf type from the
    /// upstream `SpecializationRequest`. `.boundGeneric` binds the parameter
    /// to a generic candidate whose own parameters are themselves bound by
    /// `innerArguments` — the engine recursively specializes the candidate's
    /// descriptor and substitutes the resulting metadata into the outer
    /// key-arguments buffer.
    public enum Argument: Codable, Hashable, Sendable {
        case candidate(RuntimeSpecializationRequest.Candidate)
        case boundGeneric(
            baseCandidate: RuntimeSpecializationRequest.Candidate,
            innerArguments: [String: Argument],
        )
    }
}
