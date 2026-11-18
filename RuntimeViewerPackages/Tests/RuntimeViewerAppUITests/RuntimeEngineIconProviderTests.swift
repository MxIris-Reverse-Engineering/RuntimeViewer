#if os(macOS)

import AppKit
import Dependencies
import Testing
import RuntimeViewerCore
import RuntimeViewerUI
@testable import RuntimeViewerAppUI

/// A window whose engine went away keeps its source in the runtime source picker, marked
/// disconnected, and describes its icon by the engine's identifier: the provider answers with the
/// icon it last drew for that engine. The test value follows no engine manager, so every engine is
/// one the manager does not hold.
@Suite("Engine icons by identifier")
@MainActor
struct RuntimeEngineIconProviderTests {
    @Dependency(\.runtimeEngineIconProvider) private var runtimeEngineIconProvider

    @Test("an engine the manager no longer holds gets the icons last drawn for it")
    func iconProviderReturnsLastIconForDepartedEngine() {
        let engine = RuntimeEngine(source: .local, engineID: "RuntimeEngineIconProviderTests.departed")
        let listIcon = runtimeEngineIconProvider.icon(for: engine)
        let sourcePickerIcon = runtimeEngineIconProvider.sourcePickerIcon(for: engine)

        #expect(runtimeEngineIconProvider.icon(forEngineID: engine.engineID) === listIcon)
        #expect(runtimeEngineIconProvider.sourcePickerIcon(forEngineID: engine.engineID) == sourcePickerIcon)
    }

    @Test("an engine never drawn gets the generic executable icon")
    func neverDrawnEngineGetsGenericIcon() {
        let genericIcon = NSWorkspace.shared.icon(for: .unixExecutable)

        #expect(runtimeEngineIconProvider.icon(forEngineID: "RuntimeEngineIconProviderTests.neverDrawn").tiffRepresentation == genericIcon.tiffRepresentation)
        guard case .image(let image) = runtimeEngineIconProvider.sourcePickerIcon(forEngineID: "RuntimeEngineIconProviderTests.neverDrawn") else {
            Issue.record("a never-drawn engine's source picker icon is not the generic picture")
            return
        }
        #expect(image.tiffRepresentation == genericIcon.tiffRepresentation)
    }
}

#endif
