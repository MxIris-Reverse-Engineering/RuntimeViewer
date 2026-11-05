import Foundation

extension RuntimeEngine {
    /// Core's own commands, installed on every connection before any
    /// extension module's.
    ///
    /// Adding a command to Core is one line here plus the matching command
    /// struct in `RuntimeEngine+Commands.swift` /
    /// `RuntimeEngine+GenericSpecialization.swift` / `RuntimeEngine+Search.swift`.
    /// A command belonging to another module does not come here at all — see
    /// ``addCommandExtension(named:install:)``.
    static func registerBuiltInHandlers(into registrar: RuntimeEngineCommandRegistrar) {
        registrar.registerRequestCancellation()
        registrar.register(IsImageLoadedCommand.self)
        registrar.register(IsImageIndexedCommand.self)
        registrar.register(MainExecutablePathCommand.self)
        registrar.register(LoadImageCommand.self)
        registrar.registerProgress(LoadImageWithProgressCommand.self)
        registrar.register(LoadImageForBackgroundIndexingCommand.self)
        registrar.register(ReloadDataCommand.self)
        registrar.register(CanOpenImageCommand.self)
        registrar.register(RpathsCommand.self)
        registrar.register(DependenciesCommand.self)
        registrar.register(ImageNameOfObjectCommand.self)
        registrar.register(ExportModuleInfoCommand.self)
        registrar.registerProgress(ObjectsInImageCommand.self)
        registrar.register(InterfaceCommand.self)
        registrar.register(HierarchyCommand.self)
        registrar.register(SuperclassChainCommand.self)
        registrar.register(RefinedProtocolTreeCommand.self)
        registrar.register(RelationshipsCommand.self)
        registrar.register(CounterpartCommand.self)
        registrar.register(MemberAddressesCommand.self)
        registrar.register(PrivateDeclarationSourceFilesCommand.self)
        registrar.register(SpecializationRequestForObjectCommand.self)
        registrar.register(SpecializationRequestForCandidateCommand.self)
        registrar.register(RuntimePreflightCommand.self)
        registrar.register(SpecializeCommand.self)
        registrar.registerProgress(BuildInterfaceCorpusCommand.self)
        registrar.register(PrioritizeInterfaceCorpusCommand.self)
        registrar.registerProgress(RestoreInterfaceCorporaCommand.self)
        registrar.registerProgress(SearchInterfacesCommand.self)
        registrar.registerProgress(SearchMembersCommand.self)
        registrar.registerProgress(TypeRelationshipsCommand.self)
        registrar.register(InterfaceCorpusCoverageCommand.self)
        registrar.register(IndexedImagePathsCommand.self)
        registrar.register(EvictInterfaceCorpusCommand.self)
        registrar.register(SetInterfaceCorpusResidentByteLimitCommand.self)
        registrar.registerAnsweredInThisProcess(DyldRootPathCommand.self)
    }
}
