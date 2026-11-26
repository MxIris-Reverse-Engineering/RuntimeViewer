import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings

/// The Generation Options a request about an object prints with, worked out from the settings for
/// the image the object is in (proposal `generation-options-image-overrides`).
extension SettingsAccess {
    /// The options a single-object interface fetch of an object in the image uses: the image's
    /// effective Generation Options, with the transformer and the editor's `marks…` flags merged in
    /// as the content pane merges them. Every fetch that should share a `RuntimeInterfaceCache` entry
    /// with the content pane uses these, so the cache keys line up and exported text matches what the
    /// pane displays.
    public func mergedGenerationOptions(forImageAt imagePath: String, in engine: RuntimeEngine) -> RuntimeObjectInterface.GenerationOptions {
        mergingRequestOptions(into: self.generationOptions.effectiveOptions(forImageAt: imagePath, in: engine))
    }

    /// `options` with the fields a request decides — the transformer and the `marks…` flags — set as
    /// the content pane sets them.
    public func mergingRequestOptions(into options: RuntimeObjectInterface.GenerationOptions) -> RuntimeObjectInterface.GenerationOptions {
        var mergedOptions = options
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        mergedOptions.transformer = self.transformer
        mergedOptions.marksCommentStructure = self.editor.drawsCommentTags
        mergedOptions.marksAttachedMacros = self.editor.showsMacroExpansionsInline
        mergedOptions.marksCImportedTypeNames = self.editor.showsCImportedTypeNameTags
        #else
        mergedOptions.transformer = .init()
        #endif
        return mergedOptions
    }

    /// The Generation Options settings now and whenever they change — the global options or any
    /// override. Emits on the main thread.
    public nonisolated func generationOptionsSettingsObservable() -> Observable<Settings.GenerationOptionsSettings> {
        Observable<Settings.GenerationOptionsSettings>.tracking { [self] in
            MainActor.assumeIsolated {
                self.generationOptions
            }
        }
    }

    /// The image's effective Generation Options now and whenever they change. A change to the global
    /// options or to another image's override that leaves this image's options as they were emits
    /// nothing. Emits on the main thread.
    public nonisolated func effectiveGenerationOptionsObservable(
        forImageAt imagePath: String,
        in engine: RuntimeEngine
    ) -> Observable<RuntimeObjectInterface.GenerationOptions> {
        generationOptionsSettingsObservable()
            .map { $0.effectiveOptions(forImageAt: imagePath, in: engine) }
            .distinctUntilChanged()
    }
}
