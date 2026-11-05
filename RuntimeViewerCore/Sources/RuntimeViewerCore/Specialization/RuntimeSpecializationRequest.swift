import Foundation
public import SwiftStdlibToolbox

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

    @Equatable
    public struct Candidate: Codable, Hashable, Sendable, ComparableBuildable {
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
        /// Selecting such a candidate opens a nested specialization for the
        /// candidate's own generic parameters via
        /// `RuntimeSpecializationSelection.Argument.boundGeneric(...)`.
        public let isGeneric: Bool

        /// Underlying type-system kind (Swift `enum` / `struct` / `class`)
        /// projected from the upstream `SpecializationRequest.Candidate`'s
        /// `TypeName.kind`. Carries no specialization semantics — surfaced so
        /// the type-picker UI can render the matching per-kind icon next to
        /// the candidate's display name.
        public let kind: Kind

        public init(id: String, displayName: String, imagePath: String, isGeneric: Bool, kind: Kind) {
            self.id = id
            self.displayName = displayName
            self.imagePath = imagePath
            self.isGeneric = isGeneric
            self.kind = kind
        }

        public enum Kind: Codable, Hashable, Sendable, Comparable {
            case `enum`
            case `struct`
            case `class`
        }

        public static var comparableDefinition: some ComparisonStep<Self> {
            compare(\.imagePath)
            compare(\.kind)
            compare(\.displayName)
        }
    }
}
