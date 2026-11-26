import Foundation

extension Settings {
    /// The settings window's pages something outside it opens the window on, by the identifier the
    /// window registers the page under, so the caller and the window never spell it twice.
    public enum PageIdentifier: String, Sendable {
        /// Settings › Generation Options (proposal `generation-options-image-overrides`), which an
        /// image's Generation Options sheet opens for the global options.
        case generationOptions
    }
}
