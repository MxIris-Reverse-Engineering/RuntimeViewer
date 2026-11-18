import AppKit
import UniformTypeIdentifiers
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// RuntimeViewerAppCore describes the icons and colours it shows as values; RuntimeViewerAppUI draws
/// them (proposal `app-core-without-ui-models`). Every description has to come out as an image, the same
/// image every time — a view that compares the images it was given redraws only when they differ — and a
/// colour.
///
/// On the main actor because the icons are drawn there, as the app draws them.
@Suite("Drawing the icon and colour descriptors")
@MainActor
struct IconDescriptorRenderingTests {
    private static let descriptors: [IconDescriptor] =
        SystemSymbol.allCases.map(IconDescriptor.systemSymbol)
            + RuntimeImageKind.allCases.map(IconDescriptor.imageKind)
            + [
                .runtimeObject(.objc(.type(.class))),
                .glyph(RuntimeObjectIcon.glyph(text: "f", color: .green, size: 14)),
                .findResultSymbol(.match),
                .findResultSymbol(.unresolved),
                .findResultSymbol(.disclosure(isExpanded: false)),
                .findResultSymbol(.disclosure(isExpanded: true)),
                .findResultSymbol(.recursiveCall),
                .findResultSymbol(.loading),
                .findResultSymbol(.failure),
                .runtimeEngine(engineID: "no-such-engine"),
            ]

    @Test("every icon descriptor draws an image", arguments: IconDescriptorRenderingTests.descriptors)
    func everyIconDescriptorDrawsAnImage(descriptor: IconDescriptor) {
        let image = descriptor.image
        #expect(image.size.width > 0 && image.size.height > 0, "\(descriptor) drew an empty image")
    }

    @Test("the same icon descriptor gives back the same image", arguments: IconDescriptorRenderingTests.descriptors)
    func theSameIconDescriptorReturnsTheSameCachedImage(descriptor: IconDescriptor) {
        #expect(descriptor.image === descriptor.image)
    }

    @Test("a glyph is drawn at the size it names")
    func glyphIsDrawnAtItsSize() {
        let image = IconDescriptor.runtimeObject(.swift(.type(.struct)), size: 14).image
        #expect(image.size == NSSize(width: 14, height: 14))
    }

    /// The provider a test gets follows no engine manager, so it finds no engine by its identifier; the
    /// live one finds none once the engine has gone away.
    @Test("an engine the provider cannot find draws the generic executable icon")
    func anUnknownEngineIDDrawsThePlaceholder() {
        let image = IconDescriptor.runtimeEngine(engineID: "no-such-engine").image
        #expect(image.tiffRepresentation == NSWorkspace.shared.icon(for: .unixExecutable).tiffRepresentation)
    }

    @Test("each colour descriptor resolves to the colour it names", arguments: [
        (ColorDescriptor.secondaryLabel, NSColor.secondaryLabelColor),
        (.tertiaryLabel, .tertiaryLabelColor),
    ] + RuntimeImageKind.allCases.map { (ColorDescriptor.imageKind($0), $0.iconColor) })
    func colorDescriptorResolves(descriptor: ColorDescriptor, expectedColor: NSColor) {
        #expect(descriptor.color == expectedColor)
    }
}
