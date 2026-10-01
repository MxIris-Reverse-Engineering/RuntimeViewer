import Foundation
import Testing
import RuntimeViewerCore

/// The Swift index configuration is fixed when a section is built, and every
/// interface request has to find the objects that build listed.
///
/// `RuntimeSwiftSection.updateConfiguration` used to apply an index
/// configuration of its own on every interface request. When that one
/// disagreed with the configuration the section's indexer was created with —
/// created with `showCImportedTypes: false`, asked for `true` — the first request
/// re-prepared the indexer and emptied the object-to-definition map, while the
/// cached object list that fills the map stayed as it was. Every Swift object
/// in the image then failed with `invalidRuntimeObject`, which
/// `RuntimeEngine._interface` swallows, so a click in the sidebar showed
/// nothing at all. The configuration now lives in one constant that only the
/// indexer's initializer reads.
///
/// `libswiftObservation` indexes in well under a second and carries both kinds
/// of type the configuration decides about: its own Swift types and the
/// C-imported `os_unfair_lock_s`.
@Suite("Swift index configuration")
struct SwiftIndexConfigurationTests {
    private static let observationPath = "/usr/lib/swift/libswiftObservation.dylib"

    private static let cImportedTypeName = "__C.os_unfair_lock_s"

    private static func makeEngine(engineID: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: engineID)
        try await engine.connect()
        try await engine.loadImage(at: observationPath)
        return engine
    }

    private static func swiftTypeObjects(in engine: RuntimeEngine) async throws -> [RuntimeObject] {
        let objects = try await engine.objects(in: observationPath)
        return objects
            .filter { if case .swift(.type) = $0.kind { true } else { false } }
            .sorted { $0.name < $1.name }
    }

    @Test("Every Swift type the image lists yields an interface, not just the first one asked for")
    func everyListedSwiftTypeYieldsAnInterface() async throws {
        let engine = try await Self.makeEngine(engineID: "test-swift-index-configuration-listed-types")
        let swiftTypeObjects = try await Self.swiftTypeObjects(in: engine)
        try #require(swiftTypeObjects.count > 1, "libswiftObservation should list several Swift types")

        var objectsWithoutInterface: [String] = []
        for swiftTypeObject in swiftTypeObjects {
            let interface = try await engine.interface(for: swiftTypeObject, options: .init())
            if interface == nil {
                objectsWithoutInterface.append(swiftTypeObject.displayName)
            }
        }
        #expect(objectsWithoutInterface.isEmpty, "No interface for: \(objectsWithoutInterface)")
    }

    @Test("C-imported types are listed and yield an interface")
    func cImportedTypesAreListedAndYieldAnInterface() async throws {
        let engine = try await Self.makeEngine(engineID: "test-swift-index-configuration-c-imported-types")
        let swiftTypeObjects = try await Self.swiftTypeObjects(in: engine)
        let cImportedTypeObject = try #require(
            swiftTypeObjects.first { $0.displayName == Self.cImportedTypeName },
            "\(Self.cImportedTypeName) is not listed"
        )

        let interface = try await engine.interface(for: cImportedTypeObject, options: .init())
        let interfaceString = try #require(interface?.interfaceString.string, "No interface for \(Self.cImportedTypeName)")
        #expect(interfaceString.contains("os_unfair_lock_s"))
    }

    /// A type an image declares inside an extension of a C-imported type has an
    /// extension context for a parent, so the upstream indexer does not count it
    /// among the C type's `typeChildren`. While C-imported types were not
    /// indexed, the extension was listed on its own and carried the type; once
    /// they are, the extension is folded into the C type's entry, and the type
    /// has to move there with it or it vanishes from the sidebar.
    ///
    /// `libswiftCoreAudio` defines the C struct `AudioChannelLayout` and nests
    /// `UnsafePointer` and `UnsafeMutablePointer` in an extension of it.
    @Test("Types nested in an extension of a C-imported type are listed under that type")
    func typesNestedInAnExtensionOfACImportedTypeAreListed() async throws {
        let coreAudioPath = "/usr/lib/swift/libswiftCoreAudio.dylib"
        let engine = RuntimeEngine(source: .local, engineID: "test-swift-index-configuration-c-imported-extension")
        try await engine.connect()
        try await engine.loadImage(at: coreAudioPath)
        let objects = try await engine.objects(in: coreAudioPath)

        let channelLayoutObject = try #require(
            objects.first { $0.kind == .swift(.type(.struct)) && $0.displayName == "__C.AudioChannelLayout" },
            "__C.AudioChannelLayout is not listed"
        )
        let childDisplayNames = channelLayoutObject.children.map(\.displayName)
        for nestedTypeName in ["UnsafePointer", "UnsafeMutablePointer"] {
            let nestedTypeObject = try #require(
                channelLayoutObject.children.first { $0.displayName.hasSuffix("AudioChannelLayout.\(nestedTypeName)") },
                "AudioChannelLayout.\(nestedTypeName) is not listed under __C.AudioChannelLayout; its children are \(childDisplayNames)"
            )
            let interface = try await engine.interface(for: nestedTypeObject, options: .init())
            #expect(interface != nil, "No interface for \(nestedTypeObject.displayName)")
        }
    }
}
