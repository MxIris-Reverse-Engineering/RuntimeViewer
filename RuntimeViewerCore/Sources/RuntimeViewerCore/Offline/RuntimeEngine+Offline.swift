public import Foundation
public import RuntimeViewerCommunication

extension RuntimeEngine {
    /// An engine that reads `file` in this process: the images of a Mach-O
    /// file, a bundle or a dyld shared cache, and of the cache it is paired
    /// with, parsed as files — nothing is loaded or run. What the offline
    /// service runs for the one file it was started for; `connect()` without a
    /// credential starts it.
    ///
    /// Throws `RuntimeOfflineFileError` when the file or its paired cache
    /// cannot be opened.
    public init(reading file: RuntimeOfflineFile, engineID: String = UUID().uuidString) throws {
        let catalog = try RuntimeFileImageCatalog(file: file)
        guard let placeholderPath = catalog.imagePaths().first,
              let placeholderImage = catalog.machO(forImagePath: placeholderPath)
        else {
            throw RuntimeOfflineFileError.unsupportedContent(file.url)
        }
        self.init(
            source: file.source,
            engineID: engineID,
            hostInfo: RuntimeHostInfo(
                hostID: RuntimeNetworkBonjour.localInstanceID,
                hostName: RuntimeNetworkBonjour.localHostName,
            ),
            originChain: [RuntimeNetworkBonjour.localInstanceID],
            pushesRuntimeData: true,
            bookmarkScope: nil,
            imageIndex: RuntimeImageIndex(catalog: catalog, placeholderImage: placeholderImage),
        )
    }
}
