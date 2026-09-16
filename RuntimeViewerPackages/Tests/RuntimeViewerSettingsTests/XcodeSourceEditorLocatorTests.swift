#if os(macOS)

import Foundation
import Testing

@testable import RuntimeViewerSettings

/// Pins the search order, which is the whole content of the Settings › Editor › Xcode picker.
///
/// The ordering rule is a decision, not an implementation detail: an explicit choice outranks
/// even a copy embedded in the app, because naming an Xcode and being served a different editor
/// is exactly what the setting exists to prevent. Automatic keeps the order that shipped before
/// the picker existed.
///
/// Everything asserted here is machine-independent. `/Applications/Xcode.app` appears because the
/// locator appends it as a literal last resort, not because this machine has one.
@Suite("XcodeSourceEditorLocator search order")
struct XcodeSourceEditorLocatorTests {
    private static let chosenXcodeURL = URL(fileURLWithPath: "/Volumes/Elsewhere/Xcode-Chosen.app")

    private var chosenFrameworksDirectory: URL {
        XcodeSourceEditorLocator.sharedFrameworksDirectory(of: Self.chosenXcodeURL)
    }

    @Test("an explicit choice is searched first")
    func explicitChoiceComesFirst() {
        let directories = XcodeSourceEditorLocator.candidateDirectories(preferring: Self.chosenXcodeURL)
        #expect(directories.first == chosenFrameworksDirectory)
    }

    @Test("an explicit choice is prepended, and changes nothing else")
    func explicitChoiceOnlyPrepends() {
        let automatic = XcodeSourceEditorLocator.candidateDirectories(preferring: nil)
        let preferred = XcodeSourceEditorLocator.candidateDirectories(preferring: Self.chosenXcodeURL)

        #expect(preferred == [chosenFrameworksDirectory] + automatic)
    }

    @Test("choosing a copy that is already in the automatic order does not duplicate it")
    func choosingAnAutomaticEntryDoesNotDuplicateIt() {
        // The locator appends this path literally, so it is in the automatic order on every
        // machine — whether or not anything is installed there.
        let fallbackXcodeURL = URL(fileURLWithPath: "/Applications/Xcode.app")
        let fallbackFrameworksDirectory = XcodeSourceEditorLocator.sharedFrameworksDirectory(of: fallbackXcodeURL)

        let directories = XcodeSourceEditorLocator.candidateDirectories(preferring: fallbackXcodeURL)

        #expect(directories.first == fallbackFrameworksDirectory)
        #expect(directories.filter { $0 == fallbackFrameworksDirectory }.count == 1)
    }

    @Test("a copy that is gone still describes itself, so the picker can show the stored choice")
    func missingCopyStillDescribesItself() {
        let installation = XcodeSourceEditorLocator.XcodeInstallation(bundleURL: Self.chosenXcodeURL)

        // No bundle to read a version out of, so the label falls back to the file name — which is
        // what the picker shows for a stored choice whose Xcode has since been deleted.
        #expect(installation.version == nil)
        #expect(installation.displayName == "Xcode-Chosen")
        #expect(installation.providesRequiredFrameworks == false)
        #expect(installation.id == Self.chosenXcodeURL.path)
    }
}

#endif
