import Dependencies

private enum SettingsKey: DependencyKey {
    static let liveValue = Settings.shared
    static let previewValue = Settings()
}

extension DependencyValues {
    public var settings: Settings {
        get { self[SettingsKey.self] }
        set { self[SettingsKey.self] = newValue }
    }
}
