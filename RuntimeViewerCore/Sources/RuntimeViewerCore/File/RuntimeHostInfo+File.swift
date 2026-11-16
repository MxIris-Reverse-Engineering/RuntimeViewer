import Foundation
import RuntimeViewerCommunication

extension RuntimeHostInfo {
    /// The host file engines are listed under: a section of their own in
    /// the engine menu, whichever machine's disk the file came from.
    public static let files = RuntimeHostInfo(hostID: "files", hostName: "Files")
}
