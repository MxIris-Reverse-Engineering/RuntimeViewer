extension RuntimeEngine {
    /// The name of a RuntimeEngine command, as a short name plus the namespace
    /// prefix every peer matches on.
    ///
    /// A `RawRepresentable` struct rather than an enum so that **another module
    /// can declare commands of its own** — the whole point of
    /// ``RuntimeEngine/addCommandExtension(named:install:)``. The type is
    /// `public` for that reason; the built-in constants below deliberately are
    /// not, because a command name Core uses internally is not API and opening
    /// it would freeze every one of them.
    ///
    /// What is lost against the old enum is `CaseIterable`, and with it the
    /// compile-time guarantee that no two cases share a name. That check moved
    /// to ``RuntimeEngineCommandRegistrar``, which rejects a duplicate as it is
    /// installed — strictly stronger, because it also catches two extension
    /// modules that collide without either knowing about the other.
    public struct CommandName: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        /// The short name, which is what a declaration site writes:
        /// `imageList`, `processList` and the like.
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// The namespace every command name carries, whichever module declares
        /// it. **Not to be changed.**
        ///
        /// It is half of the wire contract: a peer matches on the assembled
        /// string, and payloads already installed on devices and verified there
        /// match on this prefix. Commands that move to another module still
        /// assemble the same string, so moving them costs the wire format
        /// nothing — that is deliberate. A "cleaner" prefix naming the module a
        /// command now lives in would turn every deployed payload into a peer
        /// that cannot recognize it.
        public static let namespacePrefix = "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine."

        /// The full string a peer matches on.
        public var commandName: String {
            Self.namespacePrefix + rawValue
        }

        public var description: String {
            commandName
        }
    }
}

// MARK: - Built-in commands

/// Core's own commands. Internal on purpose — see the type's note.
extension RuntimeEngine.CommandName {
    static let imageList = Self("imageList")
    static let imageNodes = Self("imageNodes")
    static let loadImage = Self("loadImage")
    /// `loadImage` as a `RuntimeEngineProgressCommand`: same work, but the
    /// section factories' indexing progress is pushed back to the caller.
    /// A separate command rather than a widening of `loadImage`, because
    /// a progress request ships a different wire envelope.
    static let loadImageWithProgress = Self("loadImageWithProgress")
    static let isImageLoaded = Self("isImageLoaded")
    static let isImageIndexed = Self("isImageIndexed")
    static let mainExecutablePath = Self("mainExecutablePath")
    static let loadImageForBackgroundIndexing = Self("loadImageForBackgroundIndexing")
    static let canOpenImage = Self("canOpenImage")
    static let rpathsForImage = Self("rpathsForImage")
    static let dependenciesForImage = Self("dependenciesForImage")
    static let runtimeObjectHierarchy = Self("runtimeObjectHierarchy")
    static let runtimeRelationshipsForObject = Self("runtimeRelationshipsForObject")
    static let runtimeCounterpartForObject = Self("runtimeCounterpartForObject")
    static let runtimeObjectInfo = Self("runtimeObjectInfo")
    static let imageNameOfClassName = Self("imageNameOfClassName")
    static let observeRuntime = Self("observeRuntime")
    static let runtimeInterfaceExportModuleInfo = Self("runtimeInterfaceExportModuleInfo")
    static let runtimeInterfaceForRuntimeObjectInImageWithOptions = Self("runtimeInterfaceForRuntimeObjectInImageWithOptions")
    static let runtimeObjectsOfKindInImage = Self("runtimeObjectsOfKindInImage")
    static let runtimeObjectsInImage = Self("runtimeObjectsInImage")
    static let imageDidLoad = Self("imageDidLoad")
    static let memberAddresses = Self("memberAddresses")
    static let engineList = Self("engineList")
    static let engineListChanged = Self("engineListChanged")
    /// Shared side channel for `RuntimeEngineProgressCommand` pushes.
    /// Carries `RuntimeEngineProgressPush` frames routed by token, so a
    /// single command name serves every progress-bearing command type.
    static let progressEvent = Self("progressEvent")
    /// Withdraws one request the peer is serving, named by the
    /// `requestIdentifier` its envelope carried. Expects no reply, and is
    /// sent only for command types that opt in through
    /// `RuntimeEngineProgressCommand.cancelsAcrossConnections`.
    static let cancelRequest = Self("cancelRequest")
    static let specializationRequest = Self("specializationRequest")
    static let specializationRequestForCandidate = Self("specializationRequestForCandidate")
    static let runtimePreflight = Self("runtimePreflight")
    static let specialize = Self("specialize")
    static let dataDidChange = Self("dataDidChange")
    /// `reloadData(isReloadImageNodes:)` forwarded to the process that
    /// owns the images, so a client engine never reads its own dyld state.
    static let reloadData = Self("reloadData")
    /// The Find navigator's commands; see `RuntimeEngine+Search.swift`.
    static let buildInterfaceCorpus = Self("buildInterfaceCorpus")
    static let prioritizeInterfaceCorpus = Self("prioritizeInterfaceCorpus")
    static let searchInterfaces = Self("searchInterfaces")
    static let searchMembers = Self("searchMembers")
    static let typeRelationships = Self("typeRelationships")
    static let interfaceCorpusCoverage = Self("interfaceCorpusCoverage")
    static let indexedImagePaths = Self("indexedImagePaths")
    static let evictInterfaceCorpus = Self("evictInterfaceCorpus")
    static let setInterfaceCorpusResidentByteLimit = Self("setInterfaceCorpusResidentByteLimit")
    /// The `DYLD_ROOT_PATH` of the process that owns the peer's images;
    /// see `RuntimeEngine+ImagePathCanonicalization.swift`.
    static let dyldRootPath = Self("dyldRootPath")
}
