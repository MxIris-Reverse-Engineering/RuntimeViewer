#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Per-row backing model for the type-picker popover under the generic
/// specialization sheet.
///
/// Wraps a single `RuntimeSpecializationRequest.Candidate` so the popover can
/// reuse the shared `RuntimeObjectCellView` instead of hand-rolling its own
/// cell. Candidates are immutable values, so every piece of display state is
/// computed once at init and never refreshed.
///
/// - `primaryIcon` mirrors the upstream type-system kind (Swift enum / struct
///   / class) via `RuntimeObjectIcon.icon(for:)`.
/// - `secondaryIcon` shows the generic badge when `candidate.isGeneric` is
///   true (selecting a generic candidate opens a nested specialization);
///   otherwise it stays `nil` so the row collapses the icon slot.
/// - Each icon carries the tooltip `RuntimeObjectIcon` gives it.
/// - `title` is the candidate's display name, `subtitle` is the originating
///   image path so users can disambiguate same-named types defined in
///   different images.
public final class SpecializationTypePickerCellViewModel: NSObject, @unchecked Sendable {
    public let candidate: RuntimeSpecializationRequest.Candidate

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(candidate: RuntimeSpecializationRequest.Candidate) {
        self.candidate = candidate
        let iconSize = RuntimeObjectIcon.defaultIconSize
        self.appearance = RuntimeObjectCellAppearance(
            primaryIcon: .runtimeObject(candidate.kind.runtimeObjectKind, size: iconSize),
            primaryTooltip: RuntimeObjectIcon.tooltip(for: candidate.kind.runtimeObjectKind),
            secondaryIcon: candidate.isGeneric ? .glyph(RuntimeObjectIcon.genericGlyph(size: iconSize)) : nil,
            secondaryTooltip: candidate.isGeneric ? RuntimeObjectIcon.tooltipForGeneric : nil,
            title: RowText(candidate.displayName, fontSize: 12),
            subtitle: RowText(candidate.imagePath.lastPathComponent, role: .secondary, fontSize: 10)
        )
        super.init()
    }
}

extension RuntimeSpecializationRequest.Candidate.Kind {
    /// Project the wire-level candidate kind onto the shared
    /// `RuntimeObjectKind` so the cell view model can route through the
    /// existing `RuntimeObjectIcon` lookup table without duplicating its
    /// (text, color) catalog.
    fileprivate var runtimeObjectKind: RuntimeObjectKind {
        switch self {
        case .enum: return .swift(.type(.enum))
        case .struct: return .swift(.type(.struct))
        case .class: return .swift(.type(.class))
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

// `Differentiable` conformance intentionally omitted: row identity is
// owned by `CandidateBox` (= `DifferentiableBox<RuntimeSpecializationRequest.Candidate>`),
// not by this cellViewModel. The cellViewModel is constructed lazily inside
// the table's `rx.items` builder closure per render and never participates
// in the DifferenceKit diff. See "Lazy cell ViewModels for large data sets"
// in RuntimeViewerUsingAppKit/AGENTS.md for the rationale.
extension SpecializationTypePickerCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif

#endif
