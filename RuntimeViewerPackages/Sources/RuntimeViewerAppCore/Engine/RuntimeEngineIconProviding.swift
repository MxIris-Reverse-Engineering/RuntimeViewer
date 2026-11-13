#if os(macOS)
import AppKit
import Dependencies
import RuntimeViewerCore

/// The icon an engine shows in a list. Its live value is RuntimeViewerAppUI's
/// `RuntimeEngineIconProvider`, which looks icons up through Launch Services and draws the machines'
/// glyphs; this module only asks for them.
@MainActor
public protocol RuntimeEngineIconProviding: AnyObject, Sendable {
    /// The engine's icon in a list: its machine's glyph, or a picture of its own.
    func icon(for engine: RuntimeEngine) -> NSImage
}

/// RuntimeViewerAppUI adds the `DependencyKey` conformance with the live value; this module declares
/// the interface and the value tests get (swift-dependencies' "Separating interface and implementation").
package enum RuntimeEngineIconProvidingKey: TestDependencyKey {
    package static let testValue: any RuntimeEngineIconProviding = MainActor.assumeIsolated {
        PlaceholderRuntimeEngineIconProvider()
    }
}

@MainActor
extension DependencyValues {
    public var runtimeEngineIconProviding: any RuntimeEngineIconProviding {
        get { self[RuntimeEngineIconProvidingKey.self] }
        set { self[RuntimeEngineIconProvidingKey.self] = newValue }
    }
}

/// The engine icons a test gets: a blank image for each engine, the same one every time, so that a test
/// can tell which engine's icon a row shows without anything reaching Launch Services.
@MainActor
final class PlaceholderRuntimeEngineIconProvider: RuntimeEngineIconProviding {
    private var iconsByEngine: [ObjectIdentifier: NSImage] = [:]

    func icon(for engine: RuntimeEngine) -> NSImage {
        let engineIdentifier = ObjectIdentifier(engine)
        if let icon = iconsByEngine[engineIdentifier] {
            return icon
        }
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        iconsByEngine[engineIdentifier] = icon
        return icon
    }
}
#endif
