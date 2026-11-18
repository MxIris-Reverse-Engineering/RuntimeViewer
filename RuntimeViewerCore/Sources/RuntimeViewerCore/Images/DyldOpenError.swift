public import Foundation
import FoundationToolbox
import MachO.dyld
import MachOKit
import SwiftDeclarationRendering

/// `dlopen` refused an image; `message` is what `dlerror()` said.
///
/// The description is dyld's message itself, both as a `LocalizedError` and
/// as a `CustomStringConvertible`, because that is all of the error that
/// leaves the process: a failure crosses an XPC connection as its
/// `localizedDescription` and a socket as its `String(describing:)`, so an
/// engine forwarding to another process — the app's "My Mac", which forwards
/// to the local XPC service — receives only that text, never this type.
public struct DyldOpenError: Swift.Error, LocalizedError, CustomStringConvertible {
    public let message: String?

    public var errorDescription: String? {
        message ?? "dyld could not load the image and gave no reason."
    }

    public var description: String {
        errorDescription ?? ""
    }
}
