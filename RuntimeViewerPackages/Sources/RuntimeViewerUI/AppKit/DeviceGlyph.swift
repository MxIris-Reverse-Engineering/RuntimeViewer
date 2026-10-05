#if os(macOS)

import AppKit
import UIFoundationToolbox

/// The icon standing for a machine in the engine list: a device symbol with a
/// lit screen.
///
/// This is the treatment Xcode moved to in 27, and the recipe below is **its
/// recipe**, read out of `IDEKit.RunDestinationIconProvider` rather than matched
/// by eye — two rounds of guessing at it produced something visibly different
/// both times. Xcode 26 drew the photorealistic CoreTypes icons, which is why
/// its list paired a black-bezelled iPad with a white 2010-era iPhone: that is
/// what `com.apple.device-model-code` resolves to, not a design.
///
/// `icon(for:)` builds an `NSImage(systemSymbolName:)` and applies a symbol
/// configuration from `symbolConfigurationIncludingEligibility(for:)`, which is
/// a three-colour palette — `labelColor`, then `systemCyan` and `systemBlue`
/// each blended 13% with white — rendered with
/// `NSImageSymbolColorRenderingModeGradient` on macOS 26 and later. Rendering
/// `iphone.gen3` that way reproduces Xcode's row to the byte: `#E0E0E1` for the
/// body, measured against a screenshot of it.
///
/// Two consequences worth keeping: the blues are the literal system colours and
/// **not** the accent colour (Xcode's glyphs stay blue on a Mac whose accent is
/// something else), and the screen is shaded between *two* palette entries
/// rather than within one, which is why a two-colour palette could not look
/// right however it was tuned.
///
/// The symbol name is Xcode's too, by a different route: it asks IconServices'
/// private `ISSymbol(forTypeIdentifier:)` for the device's model UTType.
/// Measured, that returns exactly what UIFoundation's public
/// `deviceSymbolName(forModelIdentifier:)` table produces — `iphone.gen3`,
/// `ipad`, `macstudio` — so the table below is used instead of the private API.
/// Xcode special-cases Apple TV to `tv`; the table says `appletv`, and that one
/// divergence is left alone.
public enum DeviceGlyph {
    /// - Parameters:
    ///   - modelIdentifier: The machine's hardware model code, as it reported
    ///     it.
    ///   - operatingSystemVersion: Its OS version string, which leads with the
    ///     platform name — `RuntimeDeviceMetadata` formats it as `"iOS 26.5.0"`,
    ///     `"macOS 27.0.0"` and so on.
    ///   - isSimulator: A simulator is drawn in one colour, with no lit screen,
    ///     so that it reads as the stand-in it is rather than as hardware.
    /// - Returns: The glyph, or `nil` when neither the model nor the platform
    ///   names a device family, leaving the caller's own fallback in charge.
    public static func image(
        forModelIdentifier modelIdentifier: String,
        operatingSystemVersion: String,
        isSimulator: Bool,
    ) -> NSImage? {
        // The model code names the exact device and the platform only names its
        // family, so the model is asked first.
        //
        // macOS resolves a model code through `com.apple.device-model-code`, and
        // that covers real hardware outright — measured, an iPhone's `hw.model`
        // is a *board* identifier (`D74AP`) rather than `iPhone15,3`, and
        // CoreTypes declares both forms. What it does not cover is a **virtual
        // machine**: `VirtualMac2,1` and its iOS equivalents resolve to a dynamic
        // type that names no family at all, which is how an iPhone VM came to be
        // listed under a picture of a Cinema Display.
        guard let symbolName = NSWorkspace.shared.box.deviceSymbolName(forModelIdentifier: modelIdentifier)
            ?? platformSymbolName(forOperatingSystemVersion: operatingSystemVersion),
            let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(isSimulator ? simulatorConfiguration() : physicalConfiguration())
        else { return nil }

        return squared(symbolImage)
    }

    /// The device family's symbol, for a model code macOS does not know.
    ///
    /// Only iOS is mapped, and deliberately: every other platform's model codes
    /// are declared — watchOS, tvOS and visionOS hardware all resolve — so a
    /// branch for them could not fire. macOS is left out for a stronger reason:
    /// a Mac VM's model code is undeclared too, and a Mac is exactly what the
    /// caller's generic fallback already suits.
    ///
    /// iPadOS reports itself as `iOS`, so an iPad whose model code is unknown
    /// gets an iPhone here. That takes a VM or hardware newer than the running
    /// macOS to reach at all, and showing the wrong iOS device beats showing a
    /// desktop display.
    private static func platformSymbolName(forOperatingSystemVersion operatingSystemVersion: String) -> String? {
        String(operatingSystemVersion.prefix { $0 != " " }) == iOSPlatformName ? iOSFallbackSymbolName : nil
    }

    /// The glyph centred in a square, which is the shape every caller wants.
    ///
    /// A symbol image is not square — `iphone.gen3` is 14×16 and `macstudio` is
    /// 19×11 — and the engine menu pins each item's image to 20×20. Handed the
    /// symbol directly it would *stretch* it, which turns a Mac Studio into a
    /// cube. Squaring here rather than at the call site keeps that from being
    /// something every future caller has to remember.
    ///
    /// Drawn through a handler rather than rasterized, so the result stays
    /// resolution-independent and re-resolves its colours when the appearance
    /// changes: the palette holds `labelColor`, which is black in a light menu
    /// and white in a dark one (measured — the same image renders both ways).
    private static func squared(_ symbolImage: NSImage) -> NSImage {
        let side = max(symbolImage.size.width, symbolImage.size.height)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let scale = min(bounds.width / symbolImage.size.width, bounds.height / symbolImage.size.height)
            let fittedSize = NSSize(width: symbolImage.size.width * scale, height: symbolImage.size.height * scale)
            symbolImage.draw(
                in: NSRect(
                    x: bounds.midX - fittedSize.width / 2,
                    y: bounds.midY - fittedSize.height / 2,
                    width: fittedSize.width,
                    height: fittedSize.height,
                )
            )
            return true
        }
    }

    /// Body, then the two the screen is shaded between.
    ///
    /// Three colours, in this order, and each value is the one Xcode uses —
    /// taken from `IDEKit.RunDestinationIconProvider`'s
    /// `symbolConfigurationIncludingEligibility(for:)` rather than matched by
    /// eye. A symbol with no screen layer (`macstudio`, `macmini`) ignores the
    /// second and third, which is correct: those machines have no display to
    /// light up.
    ///
    /// Rebuilt per call rather than cached. `blended(withFraction:of:)` has to
    /// resolve its receiver to a concrete colour space, which pins a dynamic
    /// system colour to whatever appearance is current at that moment — a
    /// cached configuration would keep the appearance it was first built under.
    /// `labelColor` is left unblended and so still re-resolves at draw time.
    private static func physicalConfiguration() -> NSImage.SymbolConfiguration {
        let screenColors = [NSColor.systemCyan, NSColor.systemBlue].map {
            $0.blended(withFraction: screenWhiteFraction, of: .white) ?? $0
        }
        return gradientApplied(to: NSImage.SymbolConfiguration(paletteColors: [.labelColor] + screenColors))
    }

    /// One tone and no lit screen, which is how Xcode draws a simulator.
    private static func simulatorConfiguration() -> NSImage.SymbolConfiguration {
        gradientApplied(to: NSImage.SymbolConfiguration(hierarchicalColor: .labelColor))
    }

    /// Each palette colour shaded across its layer rather than filled flat.
    ///
    /// Xcode's screens are not one blue — they run lighter at the top — and a
    /// flat fill is visibly not the same picture. macOS 26 added the switch for
    /// it (`NSImageSymbolColorRenderingMode`); Xcode applies it behind the same
    /// availability check, and before that there is no way to ask for it, so
    /// those systems keep the flat fill rather than losing the colours.
    private static func gradientApplied(to configuration: NSImage.SymbolConfiguration) -> NSImage.SymbolConfiguration {
        guard #available(macOS 26.0, *) else { return configuration }
        return configuration.applying(NSImage.SymbolConfiguration(colorRenderingMode: .gradient))
    }

    private static let screenWhiteFraction: CGFloat = 0.13

    private static let iOSPlatformName = "iOS"

    private static let iOSFallbackSymbolName = "iphone.gen3"
}

#endif
