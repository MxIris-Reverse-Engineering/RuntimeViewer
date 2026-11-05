import Foundation
import Semantic

/// What printing one object came to: its print, nothing to print, or the
/// error that made the corpus skip it.
enum RuntimeInterfaceCorpusPrintOutcome: Sendable {
    case printed(RuntimeInterfaceCorpusPrint)
    case empty
    case failed(String)
}
