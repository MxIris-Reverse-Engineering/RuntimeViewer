import Dependencies
import RuntimeViewerAppCore
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension PasteboardClient {
    /// The system's general pasteboard.
    public static let general = PasteboardClient { string in
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

/// The live value of RuntimeViewerAppCore's `pasteboardClient`, which declares only the interface and
/// the value tests get.
extension PasteboardClientKey: DependencyKey {
    package static let liveValue = PasteboardClient.general
}
