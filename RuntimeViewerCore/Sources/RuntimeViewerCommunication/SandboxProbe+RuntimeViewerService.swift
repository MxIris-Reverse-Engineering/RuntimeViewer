#if os(macOS) || targetEnvironment(macCatalyst)

public import RuntimeViewerUtilities

extension SandboxProbe {
    /// Whether `pid`'s sandbox would deny a lookup of *this project's* helper
    /// Mach service, and therefore forces the localhost-socket transport
    /// instead of the XPC one.
    ///
    /// The probe itself lives in `RuntimeViewerUtilities` and knows no service
    /// names. Binding it to ``RuntimeViewerMachServiceName`` is the connection
    /// layer's business, because choosing between the two transports is.
    public static func isRuntimeViewerServiceMachLookupBlocked(pid: Int32) -> Bool {
        isMachLookupBlocked(pid: pid, globalName: RuntimeViewerMachServiceName)
    }
}

#endif
