import Foundation
import ObjCDeclarationRendering
#if os(macOS)
import TypeIndexing
#endif

extension RuntimeEngine {
    /// What the SDK's API notes say about how Swift imports the Objective-C
    /// class or protocol `object` names — a category's class for a category —
    /// for its header's `NS_SWIFT_NAME(...)` / `NS_REFINED_FOR_SWIFT`. Asks
    /// the type index for the platform's API notes first and, with `waits`,
    /// waits for them; empty before they are read, where the index does not
    /// run, and for an image of a platform no SDK on this Mac covers.
    func sdkSwiftImportNotes(for object: RuntimeObject, typeIndexPlatformName: String?, waits: Bool) async -> ObjCSwiftImportNotes {
        #if os(macOS)
        guard #available(macOS 13.0, *),
              let typeIndexPlatformName,
              let platform = SDKPlatform(rawValue: typeIndexPlatformName)
        else { return ObjCSwiftImportNotes() }
        await startObservingTypeIndex()
        let batch = await RuntimeTypeIndex.process.request(RuntimeTypeIndexRequest(platform: platform, moduleNames: [], metadataSources: []))
        if waits {
            await batch?.value
        }
        switch object.kind {
        case .objc(.type(.class)):
            return await RuntimeTypeIndex.process.swiftImportNotes(forClassNamed: object.name, platform: platform)
        case .objc(.type(.protocol)):
            return await RuntimeTypeIndex.process.swiftImportNotes(forProtocolNamed: object.name, platform: platform)
        case .objc(.category):
            // A category's unique name is `ClassName(CategoryName)`; API notes
            // list its methods under the class.
            let className = object.name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? object.name
            return await RuntimeTypeIndex.process.swiftImportNotes(forClassNamed: className, platform: platform)
        default:
            return ObjCSwiftImportNotes()
        }
        #else
        return ObjCSwiftImportNotes()
        #endif
    }

    /// Asks `swiftSection`'s image of the type index and waits for it, before
    /// a print that keeps its text — the Find corpus.
    func waitForTypeIndex(of swiftSection: any RuntimeSwiftSectioning) async {
        guard RuntimeTypeNames.isEnabledInThisProcess else { return }
        await startObservingTypeIndex()
        await swiftSection.requestTypeIndex()?.value
    }

    /// Turns each batch the process's type index finishes into a
    /// `RuntimeDataChange.typeNamesResolved` broadcast to this engine's
    /// clients, so they refetch what they show. Once per engine; nothing
    /// where the index does not run.
    func startObservingTypeIndex() async {
        #if os(macOS)
        guard RuntimeTypeNames.isEnabledInThisProcess, typeIndexListenerToken == nil, #available(macOS 13.0, *) else { return }
        typeIndexListenerToken = await RuntimeTypeIndex.process.addListener { [weak self] platform in
            guard let self else { return }
            Task { await self.broadcast(.typeNamesResolved(platformName: platform.rawValue)) }
        }
        #endif
    }

    /// Where the SDK type index of the process serving this engine stands, for
    /// the Report navigator. `.empty` where the index does not run, and from a
    /// peer that predates the command: over XPC an unknown command is dropped,
    /// not answered, so an answer that has not come in two seconds reads as
    /// "no index" rather than holding the caller.
    public func typeIndexStatus() async -> RuntimeTypeIndexStatus {
        guard forwardsRequests else {
            return await localTypeIndexStatus()
        }
        return await withTaskGroup(of: RuntimeTypeIndexStatus?.self) { group in
            group.addTask { try? await self.dispatch(TypeIndexStatusCommand()) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let firstAnswer = await group.next() ?? nil
            group.cancelAll()
            return firstAnswer ?? .empty
        }
    }

    /// The local arm of `typeIndexStatus()`: this process's own index.
    func localTypeIndexStatus() async -> RuntimeTypeIndexStatus {
        #if os(macOS)
        guard RuntimeTypeNames.isEnabledInThisProcess, #available(macOS 13.0, *) else { return .empty }
        return await RuntimeTypeIndex.process.status()
        #else
        return .empty
        #endif
    }
}

/// What the Find corpus's derived data adds to its variant for the type
/// names it prints: corpora printed with resolved names, and with which SDK
/// build, are files of their own (`RuntimeInterfaceCorpusSnapshot`).
enum RuntimeTypeNamesCorpusVariant {
    /// `TypeNames-<SDK version-build>` in a process that resolves type names
    /// with an installed macOS SDK — the SDK a Mac's shared cache images, macOS
    /// and Mac Catalyst alike, are read against — and `UnresolvedTypeNames`
    /// otherwise.
    static let component: String = {
        #if os(macOS)
        if RuntimeTypeNames.isEnabledInThisProcess, #available(macOS 13.0, *),
           let sdkSettings = TypeIndexingAvailability.availability(for: .macOS).sdkSettings {
            return "TypeNames-\(sdkSettings.cacheDirectoryComponent)"
        }
        #endif
        return "UnresolvedTypeNames"
    }()
}
