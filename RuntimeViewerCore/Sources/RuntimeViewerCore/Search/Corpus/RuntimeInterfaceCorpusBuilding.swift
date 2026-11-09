import Foundation

/// What the store needs from the engine to build an image's corpus. The
/// engine conforms; the store never sees a section.
protocol RuntimeInterfaceCorpusBuilding: AnyObject, Sendable {
    /// What one build lists and prints the image with, held by the store
    /// until the build's prints are in and let go of before their corpus is
    /// assembled. The engine's prints Swift on a section made for the build
    /// alone (proposal `throwaway-corpus-swift-section`): printing every
    /// definition of an image resolves every member and symbol of it, which
    /// a definition keeps for as long as it lives, and the section the
    /// content pane uses must not be left holding all of them. Throws
    /// `RuntimeInterfaceCorpusBuildError.imageNotIndexed` when the image's
    /// sections are gone.
    func corpusPrinting(forImageAt imagePath: String) async throws -> any RuntimeInterfaceCorpusPrinting
}
