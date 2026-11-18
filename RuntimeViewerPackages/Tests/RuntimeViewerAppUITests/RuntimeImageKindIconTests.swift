import AppKit
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI
import RuntimeViewerAppTestingSupport

/// How each kind of image is drawn (proposal `image-kind-icons`): a template symbol, in the colour
/// Xcode draws that kind of file in, and the same symbol already in that colour for a view that draws
/// an image as it is. RuntimeViewerAppCore names the kind; RuntimeViewerAppUI draws it (proposal
/// `app-core-without-ui-models`).
@Suite("Image kind icons")
struct RuntimeImageKindIconTests {
    @Test("every kind has a template icon, so a list draws it in its own colour", arguments: RuntimeImageKind.allCases)
    func iconIsTemplate(kind: RuntimeImageKind) {
        #expect(kind.icon.isTemplate)
    }

    // MARK: - Colours

    /// Xcode's `doc-lightBlue` as DVTUserInterfaceKit's asset catalog lists it (Xcode 27.2): sRGB
    /// 70, 169, 255 in the light appearance and 66, 173, 255 in the dark. Not a system colour.
    static let xcodeLightBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 66 / 255, green: 173 / 255, blue: 255 / 255, alpha: 1)
            : NSColor(srgbRed: 70 / 255, green: 169 / 255, blue: 255 / 255, alpha: 1)
    }

    /// Xcode's `doc-steel`, from the same catalog: Display P3 98, 127, 147 in the light appearance and
    /// sRGB 183, 213, 235 in the dark. Not a system colour.
    static let xcodeSteel = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 183 / 255, green: 213 / 255, blue: 235 / 255, alpha: 1)
            : NSColor(displayP3Red: 98 / 255, green: 127 / 255, blue: 147 / 255, alpha: 1)
    }

    @Test(
        "a kind's colour is the one Xcode draws that kind of file in, in the light and the dark appearance",
        arguments: [
            (RuntimeImageKind.folder, RuntimeImageKindIconTests.xcodeLightBlue),
            (.bundle, RuntimeImageKindIconTests.xcodeLightBlue),
            (.applicationExtension, RuntimeImageKindIconTests.xcodeLightBlue),
            (.systemExtension, RuntimeImageKindIconTests.xcodeLightBlue),
            (.kernelExtension, RuntimeImageKindIconTests.xcodeLightBlue),
            (.preferencePane, RuntimeImageKindIconTests.xcodeLightBlue),
            (.screenSaver, RuntimeImageKindIconTests.xcodeLightBlue),
            // DVTUserInterfaceKit's `doc-yellow` names the system colour.
            (.framework, NSColor.systemYellow),
            // Xcode gives an app's icon no colour and draws it in this one.
            (.application, .secondaryLabelColor),
            (.xpcService, RuntimeImageKindIconTests.xcodeSteel),
            (.dynamicLibrary, RuntimeImageKindIconTests.xcodeSteel),
            // Xcode's for a file it has no other icon for (`public.item`).
            (.image, RuntimeImageKindIconTests.xcodeSteel),
        ]
    )
    func iconColor(kind: RuntimeImageKind, expectedColor: NSColor) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(ImageColorSampling.isSameColor(kind.iconColor, expectedColor, in: appearance), "in \(appearance.rawValue)")
        }
    }

    @Test("a kind's coloured icon is drawn as it is, in the kind's colour", arguments: RuntimeImageKind.allCases)
    func coloredIcon(kind: RuntimeImageKind) {
        #expect(!kind.coloredIcon.isTemplate, "a template image would be drawn in the colour of the view or the menu")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(ImageColorSampling.isDrawn(kind.coloredIcon, in: kind.iconColor, appearance: appearance), "in \(appearance.rawValue)")
        }
    }
}
