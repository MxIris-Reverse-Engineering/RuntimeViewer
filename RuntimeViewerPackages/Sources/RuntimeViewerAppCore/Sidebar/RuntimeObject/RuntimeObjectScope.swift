import Foundation
import RuntimeViewerCore

/// User-configured scope applied to the sidebar before text search runs.
///
/// Independent from `FilterMode` (search engine) and the text search field:
/// the sidebar pipeline narrows nodes by `RuntimeObjectScope` first, then
/// hands the survivors to `FilterEngine.filter` for fuzzy/contains matching.
public struct RuntimeObjectScope: Hashable, Sendable {
    /// Tristate constraint applied to one `Property`.
    ///
    /// The raw values are what a remembered scope stores (see
    /// `RuntimeObjectScopeMemory`), so never rename one.
    public enum PropertyState: String, Hashable, Sendable {
        /// No constraint — objects with or without the property both pass.
        case any
        /// Object must carry the property.
        case only
        /// Object must NOT carry the property.
        case exclude
    }

    /// One row of the scope popover's Properties section, in display order.
    /// A row filters by one or more `RuntimeObject.Properties` flags, and an
    /// object has the property when it carries any of them.
    ///
    /// The raw values are what a remembered scope stores (see
    /// `RuntimeObjectScopeMemory`), so never rename one: a scope remembered
    /// under the old name would quietly lose that constraint.
    public enum Property: String, Hashable, CaseIterable, Sendable {
        case generic
        case specialized
        case objcImplementation
        case bridgedSwiftClass
        case bridgedSwiftProtocol
        case swiftDefined
        case localType
        case positionNamedLocalType
        case notExported

        /// The rows that filter by `flag`. Exhaustive on purpose: a flag added
        /// to `RuntimeObject.Properties.Flag` does not build until it has a
        /// row here — a new case, or an existing one when it is another face
        /// of the same thing. A flag belongs to at least one row, and to more
        /// than one when two rows overlap.
        public static func rows(filtering flag: RuntimeObject.Properties.Flag) -> [Property] {
            switch flag {
            case .isGeneric: return [.generic]
            case .isSpecialized: return [.specialized]
            case .isObjCImplementation: return [.objcImplementation]
            // One bridged class is listed twice, and each entry carries its
            // own flag: the Objective-C class `isSwiftClass`, the Swift class
            // `isObjCClass`. One row selects both. The Objective-C entry is
            // also the Objective-C face of a Swift-defined type, which
            // `swiftDefined` selects together with the protocols, leaving the
            // Swift entries alone.
            case .isSwiftClass: return [.bridgedSwiftClass, .swiftDefined]
            case .isObjCClass: return [.bridgedSwiftClass]
            // The same for an `@objc` protocol declared in Swift: the
            // Objective-C entry `isSwiftProtocol`, the Swift entry
            // `isObjCProtocol`, one row for both, and the Objective-C entry in
            // `swiftDefined` too.
            case .isSwiftProtocol: return [.bridgedSwiftProtocol, .swiftDefined]
            case .isObjCProtocol: return [.bridgedSwiftProtocol]
            case .isLocalType: return [.localType]
            case .isPositionNamedLocalType: return [.positionNamedLocalType]
            // Set only on a verdict, so Exclude keeps every object that could
            // not be judged and Only lists every type the image provably does
            // not export.
            case .isNotExported: return [.notExported]
            }
        }

        /// The flags this row filters by — read back from
        /// `rows(filtering:)`, so the two can never disagree.
        public var flags: RuntimeObject.Properties {
            Self.flagsByProperty[self, default: []]
        }

        private static let flagsByProperty: [Property: RuntimeObject.Properties] = {
            var flagsByProperty: [Property: RuntimeObject.Properties] = [:]
            for flag in RuntimeObject.Properties.Flag.allCases {
                for property in rows(filtering: flag) {
                    flagsByProperty[property, default: []].insert(RuntimeObject.Properties(flag))
                }
            }
            return flagsByProperty
        }()
    }

    /// Top-level coarse buckets that match the disclosure groups in the
    /// scope popover (C / Objective-C / Swift). `RuntimeObjectKind` itself
    /// has no such grouping, so the popover and the matcher both go through
    /// this enum to stay in sync.
    public enum KindGroup: Hashable, CaseIterable, Sendable {
        case c
        case objectiveC
        case swift

        public var title: String {
            switch self {
            case .c: return "C"
            case .objectiveC: return "Objective-C"
            case .swift: return "Swift"
            }
        }

        public var kinds: [RuntimeObjectKind] {
            let raw: [RuntimeObjectKind]
            switch self {
            case .c:
                raw = RuntimeObjectKind.C.allCases.map { .c($0) }
            case .objectiveC:
                raw = RuntimeObjectKind.ObjectiveC.allCases.map { .objc($0) }
            case .swift:
                raw = RuntimeObjectKind.Swift.allCases.map { .swift($0) }
            }
            return raw.filter { RuntimeObjectScope.allRepresentableKinds.contains($0) }
        }

        public static func of(_ kind: RuntimeObjectKind) -> KindGroup {
            switch kind {
            case .c: return .c
            case .objc: return .objectiveC
            case .swift: return .swift
            }
        }
    }

    /// `RuntimeObjectKind.allCases` minus the cases the type system admits
    /// but the runtime / Mach-O reality never produces. Used as the
    /// "everything" baseline by the toggle helpers and by the popover UI
    /// when deciding which checkboxes to draw.
    ///
    /// Currently dropped:
    /// - `.objc(.category(.protocol))` — Objective-C does not let a
    ///   category attach to a protocol.
    public static let allRepresentableKinds: Set<RuntimeObjectKind> = {
        var kinds = Set(RuntimeObjectKind.allCases)
        kinds.remove(.objc(.category(.protocol)))
        return kinds
    }()

    /// Kinds the user explicitly included. Empty means "no kind constraint";
    /// every kind is allowed. Non-empty means strict whitelist.
    public var includedKinds: Set<RuntimeObjectKind>

    /// The constrained properties. `.any` is never stored, so two scopes that
    /// constrain the same properties the same way are equal however they got
    /// there — the scope popover drops a commit that changes nothing on that
    /// equality. Read and written through `subscript(_:)`.
    private var propertyStates: [Property: PropertyState]

    public init(
        includedKinds: Set<RuntimeObjectKind> = [],
        propertyStates: [Property: PropertyState] = [:]
    ) {
        self.includedKinds = includedKinds
        self.propertyStates = propertyStates.filter { $0.value != .any }
    }

    /// The constraint on `property`; `.any` when there is none.
    public subscript(property: Property) -> PropertyState {
        get { propertyStates[property] ?? .any }
        set { propertyStates[property] = newValue == .any ? nil : newValue }
    }

    /// Whether the scope deviates from the default (everything allowed). The
    /// sidebar uses this to draw an active accent on the scope button.
    public var isActive: Bool {
        !includedKinds.isEmpty || !propertyStates.isEmpty
    }

    /// True iff `object` itself satisfies every active constraint.
    public func passes(_ object: RuntimeObject) -> Bool {
        if !includedKinds.isEmpty, !includedKinds.contains(object.kind) {
            return false
        }
        for (property, state) in propertyStates {
            let hasProperty = !object.properties.isDisjoint(with: property.flags)
            if !matchesProperty(state, has: hasProperty) {
                return false
            }
        }
        return true
    }

    /// True iff `object` or any descendant of it passes. The sidebar uses
    /// this so that a generic parent is retained when the user scopes to
    /// specialized-only — the parent itself fails, but its specialized
    /// children pull it in so the user can still expand and reach them.
    public func matchesRecursively(_ object: RuntimeObject) -> Bool {
        if passes(object) { return true }
        for child in object.children {
            if matchesRecursively(child) { return true }
        }
        return false
    }

    private func matchesProperty(_ state: PropertyState, has: Bool) -> Bool {
        switch state {
        case .any: return true
        case .only: return has
        case .exclude: return !has
        }
    }

    // MARK: - Editing helpers

    /// Flip a single kind in the user-facing selection.
    ///
    /// The model treats `includedKinds == []` as "no constraint, every
    /// kind is allowed" and the popover renders that state as every
    /// checkbox ticked. A naive `if contains { remove } else { insert }`
    /// therefore turns the very first un-tick into "include only this
    /// kind" — the opposite of what the user just expressed. To keep the
    /// UI and the model honest, expand an empty selection to its full
    /// equivalent before applying the toggle, then renormalize a full
    /// selection back down to the canonical empty form so `isActive`
    /// flips off when the user reverses every edit.
    public mutating func toggleKind(_ kind: RuntimeObjectKind) {
        let allKinds = Self.allRepresentableKinds
        if includedKinds.isEmpty {
            includedKinds = allKinds
        }
        if includedKinds.contains(kind) {
            includedKinds.remove(kind)
        } else {
            includedKinds.insert(kind)
        }
        if includedKinds == allKinds {
            includedKinds = []
        }
    }

    /// Flip every kind that belongs to `group` as one operation, with the
    /// same empty-as-all expansion / renormalization as `toggleKind`. If
    /// the group is currently in a partially-selected (mixed) state, the
    /// toggle treats it as "selected" and strips the whole group out —
    /// matching the NSButton tristate semantics where a mixed click is
    /// expected to commit to a definite off state.
    public mutating func toggleGroup(_ group: KindGroup) {
        let allKinds = Self.allRepresentableKinds
        if includedKinds.isEmpty {
            includedKinds = allKinds
        }
        let groupKinds = Set(group.kinds)
        let selectedInGroup = includedKinds.intersection(groupKinds)
        if selectedInGroup.isEmpty {
            includedKinds.formUnion(groupKinds)
        } else {
            includedKinds.subtract(groupKinds)
        }
        if includedKinds == allKinds {
            includedKinds = []
        }
    }
}

// MARK: - Persistence

/// How a remembered scope is stored (`RuntimeObjectScopeMemory`):
/// `{"excludedKinds": [...], "propertyStates": {"notExported": "exclude"}}`,
/// either key left out when it holds nothing.
///
/// The kinds are stored as the ones the scope leaves out, not the ones it lets
/// in. `includedKinds` is a whitelist, so a kind a later release adds would be
/// missing from every whitelist remembered before it, and those scopes would
/// hide objects of a kind the user never saw, let alone chose to hide.
///
/// Reading is lenient: a kind, a property or a state this release does not
/// know costs that entry, not the whole scope — a file written by a later
/// release still restores everything this one understands.
extension RuntimeObjectScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case excludedKinds
        case propertyStates
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let excludedKinds = includedKinds.isEmpty ? [] : Self.allRepresentableKinds.subtracting(includedKinds).sorted()
        if !excludedKinds.isEmpty {
            try container.encode(excludedKinds, forKey: .excludedKinds)
        }
        let storedPropertyStates = Dictionary(uniqueKeysWithValues: propertyStates.map { ($0.key.rawValue, $0.value.rawValue) })
        if !storedPropertyStates.isEmpty {
            try container.encode(storedPropertyStates, forKey: .propertyStates)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let excludedKinds = try container.decodeIfPresent([LenientlyDecodedKind].self, forKey: .excludedKinds)?.compactMap(\.kind) ?? []
        let storedPropertyStates = try container.decodeIfPresent([String: String].self, forKey: .propertyStates) ?? [:]
        var propertyStates: [Property: PropertyState] = [:]
        for (propertyName, stateName) in storedPropertyStates {
            guard let property = Property(rawValue: propertyName), let state = PropertyState(rawValue: stateName) else { continue }
            propertyStates[property] = state
        }
        // Every kind left out: the model has no "nothing at all", and an empty
        // whitelist already means no constraint, which is what unticking every
        // kind in the popover gives too.
        let includedKinds = Self.allRepresentableKinds.subtracting(excludedKinds)
        self.init(
            includedKinds: includedKinds == Self.allRepresentableKinds ? [] : includedKinds,
            propertyStates: propertyStates
        )
    }

    /// One stored kind, or `nil` for one this release cannot decode.
    private struct LenientlyDecodedKind: Decodable {
        let kind: RuntimeObjectKind?

        init(from decoder: any Decoder) throws {
            kind = try? RuntimeObjectKind(from: decoder)
        }
    }
}

/// Kept whole or dropped whole: under the dictionary of an engine's images, a
/// scope that does not decode costs its own image and nothing more.
extension RuntimeObjectScope: LenientlyDecodable {
    public static func decodedLeniently(from jsonObject: Any, diagnostics: inout [String]) -> RuntimeObjectScope? {
        try? JSONDecoder.decodeFromJSONObject(RuntimeObjectScope.self, jsonObject)
    }
}
