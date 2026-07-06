import Foundation
import RuntimeViewerCore

/// User-configured scope applied to the sidebar before text search runs.
///
/// Independent from `FilterMode` (search engine) and the text search field:
/// the sidebar pipeline narrows nodes by `RuntimeObjectScope` first, then
/// hands the survivors to `FilterEngine.filter` for fuzzy/contains matching.
public struct RuntimeObjectScope: Hashable, Sendable {
    /// Tristate constraint applied to one bit of `RuntimeObject.Properties`.
    public enum PropertyState: Hashable, Sendable {
        /// No constraint — objects with or without the property both pass.
        case any
        /// Object must carry the property.
        case only
        /// Object must NOT carry the property.
        case exclude
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

    /// Constraint on `RuntimeObject.Properties.isGeneric`.
    public var generic: PropertyState

    /// Constraint on `RuntimeObject.Properties.isSpecialized`.
    public var specialized: PropertyState

    public init(
        includedKinds: Set<RuntimeObjectKind> = [],
        generic: PropertyState = .any,
        specialized: PropertyState = .any
    ) {
        self.includedKinds = includedKinds
        self.generic = generic
        self.specialized = specialized
    }

    /// Whether the scope deviates from the default (everything allowed). The
    /// sidebar uses this to draw an active accent on the scope button.
    public var isActive: Bool {
        !includedKinds.isEmpty || generic != .any || specialized != .any
    }

    /// True iff `object` itself satisfies every active constraint.
    public func passes(_ object: RuntimeObject) -> Bool {
        if !includedKinds.isEmpty, !includedKinds.contains(object.kind) {
            return false
        }
        if !matchesProperty(generic, has: object.properties.contains(.isGeneric)) {
            return false
        }
        if !matchesProperty(specialized, has: object.properties.contains(.isSpecialized)) {
            return false
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
