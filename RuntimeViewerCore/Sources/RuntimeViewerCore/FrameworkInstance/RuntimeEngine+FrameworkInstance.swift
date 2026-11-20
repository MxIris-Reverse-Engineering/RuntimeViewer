public import Foundation
public import RuntimeViewerCommunication

extension RuntimeEngine {
    /// An engine over this process's images as a framework instance lists
    /// them: what the framework service runs for its instance. The images
    /// loaded when it is made — RuntimeViewer's own — are left out of its
    /// lists; the frameworks the app then loads through it, and what they
    /// bring in from outside the shared cache, are listed. `connect()`
    /// without a credential starts it.
    public init(
        servingFrameworkInstance instance: RuntimeFrameworkInstance,
        engineID: String = UUID().uuidString,
        hostInfo: RuntimeHostInfo = RuntimeHostInfo(
            hostID: RuntimeNetworkBonjour.localInstanceID,
            hostName: RuntimeNetworkBonjour.localHostName,
        )
    ) {
        let catalog = RuntimeFrameworkInstanceImageCatalog(baselineImagePaths: Set(DyldUtilities.imageNames()))
        self.init(
            source: instance.source,
            engineID: engineID,
            hostInfo: hostInfo,
            originChain: [RuntimeNetworkBonjour.localInstanceID],
            pushesRuntimeData: true,
            bookmarkScope: nil,
            imageIndex: RuntimeImageIndex(catalog: catalog, placeholderImage: .current()),
        )
    }
}
