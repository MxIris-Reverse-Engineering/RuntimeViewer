public enum RuntimeIndexingBatchReason: Sendable, Hashable {
    case appLaunch
    case imageLoaded(path: String)
    case settingsEnabled
    case manual
}
