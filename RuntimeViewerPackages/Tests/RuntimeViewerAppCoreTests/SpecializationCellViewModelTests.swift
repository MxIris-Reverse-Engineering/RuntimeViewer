#if os(macOS)

import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// A specialization row describes its text as `RowText`; the sheet draws it in the list style,
/// which is the 13-point system font, label colour for the description and secondary label colour
/// for the placeholder, truncated at the tail.
@Suite("Specialization row text")
@MainActor
struct SpecializationCellViewModelTests {
    @Test("A parameter's description is primary row text at 13 points")
    func specializationDescriptionIsPrimaryRowTextAtThirteenPoints() {
        let parameter = RuntimeSpecializationRequest.Parameter(name: "Element", displayDescription: "Element: Hashable", candidates: [])
        let row = SpecializationCellViewModel(parameterPath: [.parameter("Element")], parameter: parameter)

        #expect(row.descriptionText == RowText("Element: Hashable", fontSize: 13))
    }

    @Test("The loading placeholder is secondary row text at 13 points")
    func specializationLoadingPlaceholderIsSecondaryRowText() {
        let placeholder = SpecializationCellViewModel.loadingPlaceholder(parentPath: [.parameter("Element")])

        #expect(placeholder.descriptionText == RowText("Loading inner parameters…", role: .secondary, fontSize: 13))
    }
}

#endif
