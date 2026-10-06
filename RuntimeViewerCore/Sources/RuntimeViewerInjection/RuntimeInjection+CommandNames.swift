import RuntimeViewerCore

/// The injection commands' wire names.
///
/// Declared here, in the module that owns the commands, rather than in Core —
/// that is what `RuntimeEngine.CommandName` being a `RawRepresentable` struct
/// instead of a closed enum is for.
///
/// **They keep Core's namespace prefix, and must.** The assembled string is the
/// wire contract, and payloads already installed on devices and verified there
/// match on `com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine.`. Moving these
/// declarations between modules changes no byte that crosses a process
/// boundary; a prefix that named this module instead would turn every deployed
/// payload into a peer that cannot recognize them.
///
/// Internal, like Core's own: a command name is not API.
extension RuntimeEngine.CommandName {
    /// Whether the machine this engine belongs to can inject a payload into
    /// another of its processes, and when it cannot, why. **Registered by
    /// every engine** — it is the single source of truth for the gate, and
    /// only a machine can answer for itself.
    static let injectionCapability = Self("injectionCapability")

    /// The process table of the machine this engine belongs to. Never
    /// merged with the asking host's own processes.
    static let processList = Self("processList")

    /// The icons of a named set of application bundles on the machine this
    /// engine belongs to, as the PNG bytes in those bundles. Separate from
    /// `processList` so that the several processes of one application cost
    /// one icon between them, and so the list itself stays cheap.
    static let applicationIcons = Self("applicationIcons")

    /// Loads the payload into a process on the machine this engine belongs
    /// to. The injected server announces itself over Bonjour, so the
    /// response reports only how the attempt ended.
    static let injectIntoProcess = Self("injectIntoProcess")

    /// Tells the machine this engine belongs to that an injected process no
    /// longer needs to be kept able to run. Only a real iOS device does
    /// anything with it — see ``RuntimeInjectionService``.
    static let stopKeepingProcessAwake = Self("stopKeepingProcessAwake")
}
