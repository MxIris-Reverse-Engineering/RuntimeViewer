#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

import Foundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import DifferenceKit

/// Per-row backing model for the nested specialization sheet.
///
/// Each row owns one generic parameter (an entry in
/// `RuntimeSpecializationRequest.parameters`) plus the user's current
/// selection. Selecting a generic candidate populates `children` lazily with
/// rows for the candidate's own inner parameters; the wire-level
/// `RuntimeSpecializationSelection.Argument` is derived by walking the row
/// tree at preflight / specialize time, so the tree is the source of truth.
///
/// `parameterPath` is the dotted parameter chain from the outer-most row
/// (`["A"]`, `["A", "B"]`, …). It backs `Differentiable.differenceIdentifier`
/// so DifferenceKit's diff keeps already-expanded subtrees stable across
/// re-renders.
public final class SpecializationRowViewModel: NSObject, OutlineNodeType, @unchecked Sendable {
    public let parameterPath: [String]
    public let parameter: RuntimeSpecializationRequest.Parameter

    /// `true` for the synthetic "Loading inner parameters…" row spliced under
    /// a generic candidate while its inner specialization request is being
    /// fetched. Placeholders carry no `selectedCandidate`, so `argument`
    /// returns `nil` naturally and the outer row stays unbound for as long
    /// as the placeholder is present — no extra plumbing is required to
    /// keep "Specialize" disabled during the fetch.
    public let isPlaceholder: Bool

    @Observed
    public private(set) var selectedCandidate: RuntimeSpecializationRequest.Candidate?

    @Observed
    public private(set) var children: [SpecializationRowViewModel]

    @Observed
    public private(set) var loadState: InnerLoadState

    @Observed
    public private(set) var buttonTitle: String

    @Observed
    public private(set) var descriptionText: NSAttributedString

    /// In-flight inner-request fetch for the current `selectedCandidate`,
    /// captured so a fast re-pick can cancel the stale request before its
    /// callback would otherwise splice the wrong inner parameters in.
    private var inflightInnerFetch: Task<Void, Never>?

    public var isLeaf: Bool { children.isEmpty && loadState == .idle }

    public enum InnerLoadState: Equatable, Sendable {
        case idle
        case loading
        case failed(String)
    }

    public init(
        parameterPath: [String],
        parameter: RuntimeSpecializationRequest.Parameter
    ) {
        self.parameterPath = parameterPath
        self.parameter = parameter
        self.isPlaceholder = false
        self.selectedCandidate = nil
        self.children = []
        self.loadState = .idle
        self.buttonTitle = Self.defaultButtonTitle
        self.descriptionText = Self.makeDescriptionText(for: parameter)
        super.init()
    }

    private init(loadingPlaceholderUnder parentPath: [String]) {
        self.parameterPath = parentPath + [Self.placeholderPathSegment]
        // The synthesised parameter is never inspected — placeholders are
        // gated out by `isPlaceholder` everywhere it matters. It exists only
        // because the rest of the codebase reads `row.parameter` without
        // checking the placeholder flag first.
        self.parameter = .init(name: Self.placeholderPathSegment, displayDescription: "", candidates: [])
        self.isPlaceholder = true
        self.selectedCandidate = nil
        self.children = []
        self.loadState = .loading
        self.buttonTitle = ""
        self.descriptionText = Self.makeLoadingPlaceholderText()
        super.init()
    }

    /// Build the "Loading inner parameters…" row spliced under a generic
    /// candidate while its inner specialization request is in-flight. The
    /// row is removed (replaced with real parameter rows) once
    /// `installInnerParameters` runs.
    public static func loadingPlaceholder(parentPath: [String]) -> SpecializationRowViewModel {
        SpecializationRowViewModel(loadingPlaceholderUnder: parentPath)
    }

    // MARK: - Derived wire selection

    /// Derived `RuntimeSpecializationSelection.Argument` for this row.
    ///
    /// Returns `nil` when no candidate has been picked, or when the picked
    /// candidate is generic and any child row is itself unbound. The
    /// `nil`-propagation up the chain is what backs the sheet's
    /// "Specialize" enablement: an unbound inner row leaves the outer row
    /// unbound too.
    public var argument: RuntimeSpecializationSelection.Argument? {
        guard let selectedCandidate else { return nil }
        if !selectedCandidate.isGeneric {
            return .candidate(selectedCandidate)
        }
        // A generic candidate stays unbound until its inner-request fetch
        // installs at least one child row. Without this guard the row would
        // briefly look "bound" (a `.boundGeneric` with an empty
        // `innerArguments` dictionary) between `applyCandidate` and
        // `installInnerParameters`, flipping `canSpecialize` to true on the
        // outer level just long enough for the user to commit an incomplete
        // specialization.
        guard !children.isEmpty else { return nil }
        var innerArguments: [String: RuntimeSpecializationSelection.Argument] = [:]
        for child in children {
            guard let childArgument = child.argument else { return nil }
            innerArguments[child.parameter.name] = childArgument
        }
        return .boundGeneric(baseCandidate: selectedCandidate, innerArguments: innerArguments)
    }

    // MARK: - Mutators

    /// Re-bind the row to a new candidate. Always clears the existing child
    /// subtree so a re-pick can't carry stale inner selections forward.
    /// Generic candidates leave the row temporarily unbound until
    /// `installInnerParameters` plumbs in fresh child rows from the inner
    /// request fetch.
    public func applyCandidate(_ candidate: RuntimeSpecializationRequest.Candidate) {
        // Cancel any previous inner-request fetch so its late callback can
        // not race the new pick.
        inflightInnerFetch?.cancel()
        inflightInnerFetch = nil
        selectedCandidate = candidate
        children = []
        loadState = .idle
        buttonTitle = candidate.displayName
    }

    /// Flip the row into the loading state and splice a single
    /// "Loading inner parameters…" placeholder row under it so the outline
    /// view shows immediate feedback while the inner specialization request
    /// is in-flight. `installInnerParameters` replaces the placeholder with
    /// the real parameter rows on success; `setLoadFailed` clears it on
    /// failure.
    public func setLoading() {
        children = [SpecializationRowViewModel.loadingPlaceholder(parentPath: parameterPath)]
        loadState = .loading
    }

    /// Attach an in-flight fetch so `applyCandidate` can cancel it on a
    /// re-pick. The task is dropped (without cancellation) once it finishes
    /// naturally.
    public func attachInflightInnerFetch(_ task: Task<Void, Never>) {
        inflightInnerFetch = task
    }

    public func clearInflightInnerFetch() {
        inflightInnerFetch = nil
    }

    public func setLoadFailed(_ message: String) {
        // Drop the loading placeholder; the failure surface is the row's
        // own state, not a synthetic child row.
        children = []
        loadState = .failed(message)
    }

    /// Populate child rows from the inner specialization request's
    /// parameters, in declaration order. Called after a successful
    /// `RuntimeEngine.specializationRequest(forCandidate:in:)` round-trip.
    public func installInnerParameters(_ parameters: [RuntimeSpecializationRequest.Parameter]) {
        children = parameters.map {
            SpecializationRowViewModel(
                parameterPath: parameterPath + [$0.name],
                parameter: $0
            )
        }
        loadState = .idle
    }

    // MARK: - Display helpers

    private static let defaultButtonTitle = "Choose Type…"

    /// Sentinel name appended to a placeholder's `parameterPath` so it has a
    /// stable `differenceIdentifier` (DifferenceKit recycles by path) and so
    /// it can never collide with a real parameter name (Swift generic
    /// parameters can not contain double underscores in their type-system
    /// surface name).
    fileprivate static let placeholderPathSegment = "__loading_placeholder__"

    private static func makeDescriptionText(for parameter: RuntimeSpecializationRequest.Parameter) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: parameter.displayDescription,
            attributes: [
                .foregroundColor: NSUIColor.labelColor,
                .font: NSUIFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private static func makeLoadingPlaceholderText() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return NSAttributedString(
            string: "Loading inner parameters…",
            attributes: [
                .foregroundColor: NSUIColor.secondaryLabelColor,
                .font: NSUIFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraphStyle,
            ]
        )
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SpecializationRowViewModel: Differentiable {
    public var differenceIdentifier: [String] { parameterPath }

    public func isContentEqual(to source: SpecializationRowViewModel) -> Bool {
        parameterPath == source.parameterPath
            && isPlaceholder == source.isPlaceholder
            && selectedCandidate == source.selectedCandidate
            && loadState == source.loadState
    }
}

#endif
