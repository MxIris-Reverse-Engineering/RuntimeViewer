import Foundation
import RuntimeViewerCore

extension Settings {
    /// The Generation Options one image of one engine prints with where they differ from the
    /// global ones (proposal `generation-options-image-overrides`).
    ///
    /// An override names the options it overrides; every other option of the image follows
    /// `GenerationOptionsSettings.global`, changes to it included. Only an option whose value
    /// differs from the global one is kept, so an override never holds an option that changes
    /// nothing, and one left with no option is removed.
    ///
    /// Written by hand rather than with MetaCodable so that a stored option no
    /// ``GenerationOption`` case has any more is dropped instead of failing the whole override.
    public struct ImageGenerationOptionsOverride: Codable, Hashable, Sendable, Identifiable {
        /// The engine's key (`Settings.Indexing.EngineReference.key(for:)`) and the names it carried
        /// when the override last changed, for Settings › Generation Options to show while the
        /// engine is not connected.
        public var engine: Indexing.EngineReference

        /// The image's path in its engine's canonical spelling (`RuntimeEngine.canonicalImagePath(_:)`).
        public var imagePath: String

        /// The options the image overrides.
        public var overriddenOptions: Set<GenerationOption>

        /// The values of ``overriddenOptions``; its other fields mean nothing.
        public var values: RuntimeObjectInterface.GenerationOptions

        public init(
            engine: Indexing.EngineReference,
            imagePath: String,
            overriddenOptions: Set<GenerationOption>,
            values: RuntimeObjectInterface.GenerationOptions
        ) {
            self.engine = engine
            self.imagePath = imagePath
            self.overriddenOptions = overriddenOptions
            self.values = values
        }

        public var id: String { engine.key + "\u{0}" + imagePath }

        /// The last path component of ``imagePath``, as a list names the image.
        public var imageName: String {
            (imagePath as NSString).lastPathComponent
        }

        private enum CodingKeys: String, CodingKey {
            case engine
            case imagePath
            case overriddenOptions
            case values
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            engine = try container.decodeIfPresent(Indexing.EngineReference.self, forKey: .engine) ?? Indexing.EngineReference()
            imagePath = try container.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
            let storedOptionNames = try container.decodeIfPresent([String].self, forKey: .overriddenOptions) ?? []
            overriddenOptions = Set(storedOptionNames.compactMap(GenerationOption.init(rawValue:)))
            values = try container.decodeIfPresent(RuntimeObjectInterface.GenerationOptions.self, forKey: .values) ?? RuntimeObjectInterface.GenerationOptions()
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(engine, forKey: .engine)
            try container.encode(imagePath, forKey: .imagePath)
            // Sorted, so the same override always writes the same text.
            try container.encode(overriddenOptions.map(\.rawValue).sorted(), forKey: .overriddenOptions)
            try container.encode(values, forKey: .values)
        }
    }
}
