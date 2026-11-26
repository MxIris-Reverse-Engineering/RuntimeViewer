import Foundation
import MetaCodable
import RuntimeViewerCore

extension Settings {
    /// The Generation Options interfaces are printed with: the global ones, and what each image of
    /// each engine overrides of them (proposal `generation-options-image-overrides`).
    ///
    /// Settings › Generation Options edits ``global`` and lists ``imageOverrides``; an image's
    /// Generation Options sheet in a document window edits that image's override. Everything that
    /// prints or projects an interface asks ``effectiveOptions(forImageAt:engineKey:)`` — or the
    /// `RuntimeEngine` overloads — for the image the object is in.
    ///
    /// Until this branch existed the options lived in the app's user defaults under
    /// `generationOptions`; `SettingsAccess` moves them into ``global`` once.
    @Codable
    @MemberInit
    public struct GenerationOptionsSettings: Hashable, Sendable {
        /// What every image prints with, unless it overrides an option. Only the options
        /// ``GenerationOption`` lists are read from it: the fields a request decides for itself
        /// (`transformer`, the `marks…` flags, `waitsForTypeIndex`, `interfaceLanguage`) keep their
        /// defaults and are filled in by whoever makes the request.
        @Default(RuntimeObjectInterface.GenerationOptions())
        public var global: RuntimeObjectInterface.GenerationOptions

        /// The images that override some of ``global``, at most one per engine and image.
        @Default([ImageGenerationOptionsOverride]())
        public var imageOverrides: [ImageGenerationOptionsOverride]

        public static let `default` = Self()

        /// The override of the image at `imagePath` (canonical) of the engine with `engineKey`.
        public func override(forImageAt imagePath: String, engineKey: String) -> ImageGenerationOptionsOverride? {
            imageOverrides.first { $0.engine.key == engineKey && $0.imagePath == imagePath }
        }

        /// The options the image prints with: ``global``, with the options its override names
        /// replaced by the override's values.
        public func effectiveOptions(forImageAt imagePath: String, engineKey: String) -> RuntimeObjectInterface.GenerationOptions {
            var options = global
            guard let override = override(forImageAt: imagePath, engineKey: engineKey) else { return options }
            for option in override.overriddenOptions {
                option.copyValue(from: override.values, to: &options)
            }
            return options
        }

        /// The effective options of every image of the engine with `engineKey` that has an override,
        /// keyed by canonical image path. Every other image of the engine prints with ``global``.
        public func effectiveOptionsByImagePath(engineKey: String) -> [String: RuntimeObjectInterface.GenerationOptions] {
            var optionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions] = [:]
            for override in imageOverrides where override.engine.key == engineKey {
                optionsByImagePath[override.imagePath] = effectiveOptions(forImageAt: override.imagePath, engineKey: engineKey)
            }
            return optionsByImagePath
        }

        /// Applies `body` to the image's effective options and records each option it changed: as an
        /// override where the new value differs from ``global``, by removing the option's override
        /// where it is the global value again. An override left with no option is removed. The
        /// override takes `engine`'s current names.
        public mutating func updateOverride(
            forImageAt imagePath: String,
            engine: Indexing.EngineReference,
            _ body: (inout RuntimeObjectInterface.GenerationOptions) -> Void
        ) {
            let previousOptions = effectiveOptions(forImageAt: imagePath, engineKey: engine.key)
            var updatedOptions = previousOptions
            body(&updatedOptions)
            var override = override(forImageAt: imagePath, engineKey: engine.key)
                ?? ImageGenerationOptionsOverride(engine: engine, imagePath: imagePath, overriddenOptions: [], values: global)
            for option in GenerationOption.allCases where !option.hasSameValue(in: previousOptions, as: updatedOptions) {
                if option.hasSameValue(in: updatedOptions, as: global) {
                    override.overriddenOptions.remove(option)
                } else {
                    option.copyValue(from: updatedOptions, to: &override.values)
                    override.overriddenOptions.insert(option)
                }
            }
            override.engine = engine
            store(override)
        }

        /// Makes `option` of the image follow ``global`` again.
        public mutating func revert(_ option: GenerationOption, forImageAt imagePath: String, engineKey: String) {
            guard var override = override(forImageAt: imagePath, engineKey: engineKey) else { return }
            override.overriddenOptions.remove(option)
            store(override)
        }

        /// Makes every option of the image follow ``global`` again.
        public mutating func removeOverride(forImageAt imagePath: String, engineKey: String) {
            imageOverrides.removeAll { $0.engine.key == engineKey && $0.imagePath == imagePath }
        }

        /// Puts `override` in place of the image's, where the image's was, or removes the image's
        /// when `override` overrides nothing.
        private mutating func store(_ override: ImageGenerationOptionsOverride) {
            let existingIndex = imageOverrides.firstIndex { $0.engine.key == override.engine.key && $0.imagePath == override.imagePath }
            switch (existingIndex, override.overriddenOptions.isEmpty) {
            case (let existingIndex?, true):
                imageOverrides.remove(at: existingIndex)
            case (let existingIndex?, false):
                if imageOverrides[existingIndex] != override {
                    imageOverrides[existingIndex] = override
                }
            case (nil, true):
                break
            case (nil, false):
                imageOverrides.append(override)
            }
        }
    }
}
