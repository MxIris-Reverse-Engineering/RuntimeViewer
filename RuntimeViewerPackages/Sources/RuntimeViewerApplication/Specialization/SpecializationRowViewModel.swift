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
        self.selectedCandidate = nil
        self.children = []
        self.loadState = .idle
        self.buttonTitle = Self.defaultButtonTitle
        self.descriptionText = Self.makeDescriptionText(for: parameter)
        super.init()
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
        selectedCandidate = candidate
        children = []
        loadState = .idle
        buttonTitle = candidate.displayName
    }

    public func setLoading() {
        loadState = .loading
    }

    public func setLoadFailed(_ message: String) {
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
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SpecializationRowViewModel: Differentiable {
    public var differenceIdentifier: [String] { parameterPath }

    public func isContentEqual(to source: SpecializationRowViewModel) -> Bool {
        parameterPath == source.parameterPath
            && selectedCandidate == source.selectedCandidate
            && loadState == source.loadState
    }
}

#endif
