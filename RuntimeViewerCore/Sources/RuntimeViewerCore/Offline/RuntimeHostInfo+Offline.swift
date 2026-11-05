import Foundation
import RuntimeViewerCommunication

extension RuntimeHostInfo {
    /// The host offline engines are listed under: a section of their own in
    /// the engine menu, whichever machine's disk the file came from.
    public static let offlineFiles = RuntimeHostInfo(hostID: "offline-files", hostName: "Offline Files")
}
