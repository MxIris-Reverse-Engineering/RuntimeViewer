public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case settingsEnabled
    case manual
    /// Triggered by an entry in `Settings.Indexing.alwaysIndexIdentifiers`.
    /// `identifier` is the raw user-supplied string (full imagePath or just
    /// the image's last path component); displayed verbatim in the popover.
    case alwaysIndex(identifier: String)
}
