import Foundation
import RuntimeViewerCommunication

extension RuntimeHostInfo {
    /// The host framework instances are listed under: a section of their own
    /// in the runtime source picker, beside the files.
    public static let frameworkInstances = RuntimeHostInfo(hostID: "frameworkInstances", hostName: "Isolated Frameworks")
}
