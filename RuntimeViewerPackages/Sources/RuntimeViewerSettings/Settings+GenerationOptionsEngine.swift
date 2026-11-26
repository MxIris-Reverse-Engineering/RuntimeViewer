import Foundation
import RuntimeViewerCore

/// The `GenerationOptionsSettings` calls for an image named the way an engine and its objects name
/// it: the engine's key and the image's canonical path are worked out here, so a caller never keys an
/// override by a spelling another caller would not find.
extension Settings.GenerationOptionsSettings {
    public func override(forImageAt imagePath: String, in engine: RuntimeEngine) -> Settings.ImageGenerationOptionsOverride? {
        override(forImageAt: engine.canonicalImagePath(imagePath), engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    public func effectiveOptions(forImageAt imagePath: String, in engine: RuntimeEngine) -> RuntimeObjectInterface.GenerationOptions {
        effectiveOptions(forImageAt: engine.canonicalImagePath(imagePath), engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    /// The effective options of `engine`'s images that have an override, keyed by canonical image
    /// path: what a Find request carries besides the global options.
    public func effectiveOptionsByImagePath(in engine: RuntimeEngine) -> [String: RuntimeObjectInterface.GenerationOptions] {
        effectiveOptionsByImagePath(engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    public mutating func updateOverride(
        forImageAt imagePath: String,
        in engine: RuntimeEngine,
        _ body: (inout RuntimeObjectInterface.GenerationOptions) -> Void
    ) {
        updateOverride(forImageAt: engine.canonicalImagePath(imagePath), engine: Settings.Indexing.EngineReference(engine: engine), body)
    }

    public mutating func revert(_ option: Settings.GenerationOption, forImageAt imagePath: String, in engine: RuntimeEngine) {
        revert(option, forImageAt: engine.canonicalImagePath(imagePath), engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    public mutating func removeOverride(forImageAt imagePath: String, in engine: RuntimeEngine) {
        removeOverride(forImageAt: engine.canonicalImagePath(imagePath), engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }
}
