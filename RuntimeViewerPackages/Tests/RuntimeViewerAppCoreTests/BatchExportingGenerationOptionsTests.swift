#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings
import Testing
@testable import RuntimeViewerAppCore

/// A batch export writes each image as its content pane shows it: under that image's own effective
/// Generation Options (proposal `generation-options-image-overrides`).
@Suite("Batch export Generation Options")
@MainActor
struct BatchExportingGenerationOptionsTests {
    @Test("each image of a batch export takes its own effective options, with the transformer")
    func batchExportUsesEachImagesOwnOptions() {
        let engine = RuntimeEngine.local
        let overriddenImage = BatchExportingImage(path: "/usr/lib/libobjc.A.dylib", name: "libobjc.A.dylib")
        let otherImage = BatchExportingImage(path: "/usr/lib/libSystem.B.dylib", name: "libSystem.B.dylib")
        var generationOptions = Settings.GenerationOptionsSettings()
        generationOptions.global.objcHeaderOptions.stripOverrides = true
        generationOptions.updateOverride(forImageAt: overriddenImage.path, in: engine) {
            $0.swiftInterfaceOptions.printFieldOffset = true
        }
        var transformer = Transformer.Configuration()
        transformer.objc.cType.isEnabled.toggle()

        let optionsByImagePath = BatchExportingProgressViewModel.generationOptionsByImagePath(
            for: [overriddenImage, otherImage],
            generationOptions: generationOptions,
            transformer: transformer,
            in: engine
        )

        #expect(optionsByImagePath[overriddenImage.path]?.swiftInterfaceOptions.printFieldOffset == true)
        #expect(optionsByImagePath[otherImage.path]?.swiftInterfaceOptions.printFieldOffset == false)
        #expect(optionsByImagePath[otherImage.path]?.objcHeaderOptions.stripOverrides == true, "the global options reach every image")
        #expect(optionsByImagePath.values.allSatisfy { $0.transformer == transformer })
    }
}

#endif
