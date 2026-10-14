public enum ProbeLibrary {
    public static var builtFor: String {
        #if targetEnvironment(simulator)
        "simulator"
        #elseif targetEnvironment(macCatalyst)
        "Mac Catalyst"
        #elseif os(macOS)
        "macOS"
        #else
        "other"
        #endif
    }
}
