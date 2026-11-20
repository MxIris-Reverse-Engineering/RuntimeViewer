public import Foundation
public import RuntimeViewerCommunication

/// One Load Frameworks: an instance of the framework service of its own,
/// started for a window, into which the frameworks the user picks are loaded
/// and run.
///
/// What the app tells the instance when it connects — only which instance it
/// is, never which frameworks. A connection to a dedicated instance that goes
/// away is re-established with a new instance and the same launch payload, so
/// a payload that named the frameworks would load again, in the new instance,
/// the framework whose constructor just crashed the old one. The frameworks
/// are loaded with ordinary load commands once the instance answers.
public struct RuntimeFrameworkInstance: Codable, Sendable, Hashable {
    /// What tells this instance apart from every other, the same frameworks
    /// loaded included.
    public var identifier: String
    /// What menus show.
    public var name: String
    /// The first framework chosen, which bookmarks are filed under.
    public var frameworkURL: URL

    public init(identifier: String = UUID().uuidString, name: String, frameworkURL: URL) {
        self.identifier = identifier
        self.name = name
        self.frameworkURL = frameworkURL
    }

    public var source: RuntimeSource {
        .frameworkInstance(name: name, frameworkURL: frameworkURL, identifier: .init(rawValue: identifier))
    }
}
