#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Foundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

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
/// - `title` is the candidate's display name, `subtitle` is the originating
///   image path so users can disambiguate same-named types defined in
///   different images.
public final class SpecializationTypePickerCellViewModel: NSObject, @unchecked Sendable {
    public let candidate: RuntimeSpecializationRequest.Candidate

    @Observed
    public private(set) var primaryIcon: NSUIImage = .init()

    @Observed
    public private(set) var secondaryIcon: NSUIImage?

    @Observed
    public private(set) var tertiaryIcon: NSUIImage?

    @Observed
    public private(set) var title: NSAttributedString = .init()

    @Observed
    public private(set) var subtitle: NSAttributedString?

    public init(candidate: RuntimeSpecializationRequest.Candidate) {
        self.candidate = candidate
        super.init()
        let iconSize = RuntimeObjectIcon.defaultIconSize
        primaryIcon = RuntimeObjectIcon.icon(for: candidate.kind.runtimeObjectKind, size: iconSize)
        secondaryIcon = candidate.isGeneric ? RuntimeObjectIcon.iconForGeneric(size: iconSize) : nil
        title = NSAttributedString {
            AText(candidate.displayName)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 12))
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
        }
        subtitle = NSAttributedString {
            AText(candidate.imagePath.lastPathComponent)
                .foregroundColor(.secondaryLabelColor)
                .font(.systemFont(ofSize: 10))
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingMiddle })
        }
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

extension SpecializationTypePickerCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeSpecializationRequest.Candidate { candidate }
    public func isContentEqual(to source: SpecializationTypePickerCellViewModel) -> Bool {
        candidate == source.candidate
    }
}

extension SpecializationTypePickerCellViewModel: RuntimeObjectCellDisplayable {
    public var primaryIconDriver: Driver<NSUIImage> { $primaryIcon.asDriver() }
    public var secondaryIconDriver: Driver<NSUIImage?> { $secondaryIcon.asDriver() }
    public var tertiaryIconDriver: Driver<NSUIImage?> { $tertiaryIcon.asDriver() }
    public var titleDriver: Driver<NSAttributedString> { $title.asDriver() }
    public var subtitleDriver: Driver<NSAttributedString?> { $subtitle.asDriver() }
}

#endif
