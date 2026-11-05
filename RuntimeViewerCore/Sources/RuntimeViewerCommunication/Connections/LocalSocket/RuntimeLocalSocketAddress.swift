import Foundation
import FoundationToolbox
import Combine

/// The addresses these connections dial and bind.
enum RuntimeLocalSocketAddress {
    /// The only address this family used before an injected payload had to
    /// reach a host across a network. Spelled once so the localhost case and
    /// the injected case are visibly the same code with a different address.
    static let loopback = "127.0.0.1"
}
