import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings

/// The Generation Options a Find search reads interfaces under, so it finds what the content pane
/// shows: the global options, and the effective options of each image of the document's engine
/// that overrides some, keyed by canonical image path (proposal `generation-options-image-overrides`).
/// A text or member search carries both to the engine, which reads every image under its own.
struct FindGenerationOptions: Equatable, Sendable {
    let global: RuntimeObjectInterface.GenerationOptions

    let byImagePath: [String: RuntimeObjectInterface.GenerationOptions]

    init(global: RuntimeObjectInterface.GenerationOptions, byImagePath: [String: RuntimeObjectInterface.GenerationOptions] = [:]) {
        self.global = global
        self.byImagePath = byImagePath
    }

    /// The options the settings give `engine`'s images now.
    init(_ settings: Settings.GenerationOptionsSettings, engine: RuntimeEngine) {
        self.init(global: settings.global, byImagePath: settings.effectiveOptionsByImagePath(in: engine))
    }

    /// The per-image options as a query carries them: `nil` when no image has options of its own.
    var queryOptionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions]? {
        byImagePath.isEmpty ? nil : byImagePath
    }
}
