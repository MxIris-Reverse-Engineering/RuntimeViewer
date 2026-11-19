import Foundation
import RuntimeViewerCore

extension RuntimeFrameworkInstance {
    /// A new instance for loading `frameworkURLs`, named after the first —
    /// "Foo.framework (Isolated)", or "Foo.framework + 2 (Isolated)" for three.
    public init(loading frameworkURLs: [URL]) {
        let firstFrameworkURL = frameworkURLs.first ?? URL(fileURLWithPath: "/")
        let otherCount = max(frameworkURLs.count - 1, 0)
        let firstName = firstFrameworkURL.lastPathComponent
        let name = otherCount == 0 ? "\(firstName) (Isolated)" : "\(firstName) + \(otherCount) (Isolated)"
        self.init(name: name, frameworkURL: firstFrameworkURL)
    }
}
