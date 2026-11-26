import Foundation
import Testing
import RuntimeViewerCore

@testable import RuntimeViewerSettings

/// How an image's Generation Options come out of the global ones and its override (proposal
/// `generation-options-image-overrides`).
@Suite("Generation Options settings")
struct GenerationOptionsSettingsTests {
    private static let engine = Settings.Indexing.EngineReference(key: "scope:local", name: "My Mac", hostName: "Mac")
    private static let otherEngine = Settings.Indexing.EngineReference(key: "process:Finder", name: "Finder", hostName: "Mac")
    private static let imagePath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let otherImagePath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    @Test("an image without an override prints with the global options")
    func effectiveOptionsEqualsGlobalWithoutOverride() {
        var settings = Settings.GenerationOptionsSettings()
        settings.global.swiftInterfaceOptions.printFieldOffset = true

        #expect(settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key) == settings.global)
        #expect(settings.override(forImageAt: Self.imagePath, engineKey: Self.engine.key) == nil)
    }

    @Test("an overridden option takes the image's value, and the others the global ones")
    func overriddenOptionUsesImageValueAndOthersFollowGlobal() {
        var settings = Settings.GenerationOptionsSettings()
        settings.global.objcHeaderOptions.stripOverrides = true

        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.printFieldOffset = true }

        let options = settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key)
        #expect(options.swiftInterfaceOptions.printFieldOffset)
        #expect(options.objcHeaderOptions.stripOverrides)
        #expect(settings.override(forImageAt: Self.imagePath, engineKey: Self.engine.key)?.overriddenOptions == [.swiftPrintFieldOffset])
    }

    @Test("a global change reaches the options an image does not override, and not the one it does")
    func changingGlobalReachesOptionsTheImageDoesNotOverride() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.printFieldOffset = true }

        settings.global.swiftInterfaceOptions.printVTableOffset = true
        settings.global.swiftInterfaceOptions.printFieldOffset = false

        let options = settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key)
        #expect(options.swiftInterfaceOptions.printVTableOffset)
        #expect(options.swiftInterfaceOptions.printFieldOffset)
    }

    @Test("setting an option back to the global value removes its override, and the other stays")
    func updatingAnOptionToTheGlobalValueRemovesItsOverride() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) {
            $0.swiftInterfaceOptions.printFieldOffset = true
            $0.swiftInterfaceOptions.memberSortOrder = .byOffset
        }

        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.printFieldOffset = false }

        #expect(settings.override(forImageAt: Self.imagePath, engineKey: Self.engine.key)?.overriddenOptions == [.swiftMemberSortOrder])
        #expect(settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key).swiftInterfaceOptions.memberSortOrder == .byOffset)
    }

    @Test("an override left with no option is removed")
    func removingTheLastOverriddenOptionRemovesTheOverride() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.objcHeaderOptions.stripCtorMethod.toggle() }
        settings.updateOverride(forImageAt: Self.otherImagePath, engine: Self.engine) { $0.objcHeaderOptions.stripDtorMethod.toggle() }

        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.objcHeaderOptions.stripCtorMethod.toggle() }
        settings.revert(.objcStripDtorMethod, forImageAt: Self.otherImagePath, engineKey: Self.engine.key)

        #expect(settings.imageOverrides.isEmpty)
    }

    @Test("a change that equals the global value records nothing")
    func changingNothingRecordsNoOverride() {
        var settings = Settings.GenerationOptionsSettings()

        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.printFieldOffset = false }

        #expect(settings.imageOverrides.isEmpty)
    }

    @Test("an override applies to its own engine and image only")
    func overridesOfOtherEnginesOrImagesDoNotApply() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.expandsMacros = true }

        #expect(!settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.otherEngine.key).swiftInterfaceOptions.expandsMacros)
        #expect(!settings.effectiveOptions(forImageAt: Self.otherImagePath, engineKey: Self.engine.key).swiftInterfaceOptions.expandsMacros)
        #expect(settings.effectiveOptionsByImagePath(engineKey: Self.engine.key).keys.sorted() == [Self.imagePath])
        #expect(settings.effectiveOptionsByImagePath(engineKey: Self.otherEngine.key).isEmpty)
    }

    @Test("removing an override brings every option of the image back to the global ones")
    func removeOverrideRestoresGlobal() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) {
            $0.swiftInterfaceOptions.expandsMacros = true
            $0.marksSwiftNamesFromAPINotes = false
        }

        settings.removeOverride(forImageAt: Self.imagePath, engineKey: Self.engine.key)

        #expect(settings.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key) == settings.global)
        #expect(settings.imageOverrides.isEmpty)
    }

    @Test("an override takes the engine's current names")
    func updatingRefreshesTheEngineNames() {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.expandsMacros = true }
        let renamedEngine = Settings.Indexing.EngineReference(key: Self.engine.key, name: "Studio", hostName: "Studio")

        settings.updateOverride(forImageAt: Self.imagePath, engine: renamedEngine) { $0.swiftInterfaceOptions.breaksLongTypes = true }

        #expect(settings.imageOverrides.map(\.engine) == [renamedEngine])
    }

    @Test("a stored option no case has any more is dropped, and the rest of the override stays")
    func unknownStoredOptionIsDroppedWithoutLosingTheOverride() throws {
        var settings = Settings.GenerationOptionsSettings()
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.expandsMacros = true }
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var overrides = try #require(encoded["imageOverrides"] as? [[String: Any]])
        overrides[0]["overriddenOptions"] = ["swift.expandsMacros", "swift.someOptionFromTheFuture"]
        encoded["imageOverrides"] = overrides

        let decoded = try JSONDecoder().decode(Settings.GenerationOptionsSettings.self, from: JSONSerialization.data(withJSONObject: encoded))

        #expect(decoded.override(forImageAt: Self.imagePath, engineKey: Self.engine.key)?.overriddenOptions == [.swiftExpandsMacros])
        #expect(decoded.effectiveOptions(forImageAt: Self.imagePath, engineKey: Self.engine.key).swiftInterfaceOptions.expandsMacros)
    }

    @Test("the settings survive encoding and decoding")
    func roundTrips() throws {
        var settings = Settings.GenerationOptionsSettings()
        settings.global.objcHeaderOptions.addIvarOffsetComments = true
        settings.updateOverride(forImageAt: Self.imagePath, engine: Self.engine) { $0.swiftInterfaceOptions.cImportedTypeNameSpelling = .cName }

        let decoded = try JSONDecoder().decode(Settings.GenerationOptionsSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded == settings)
    }
}
