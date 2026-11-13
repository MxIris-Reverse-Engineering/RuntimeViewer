import Foundation
import Dependencies
import DependenciesMacros
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Puts text on the pasteboard for the context menus' copy commands.
///
/// A dependency rather than a call to the general pasteboard so that a test
/// reads what a copy command wrote from a client of its own: the default test
/// value does nothing, and the general pasteboard is the user's — a test run
/// that wrote to it would replace whatever they had copied.
public struct PasteboardClient: Sendable {
    public var copyString: @MainActor @Sendable (String) -> Void

    public init(copyString: @escaping @MainActor @Sendable (String) -> Void) {
        self.copyString = copyString
    }
}

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

    /// Copies nothing.
    public static let inert = PasteboardClient { _ in }
}

extension DependencyValues {
    @DependencyEntry(liveValue: PasteboardClient.general)
    public var pasteboardClient = PasteboardClient.inert
}
