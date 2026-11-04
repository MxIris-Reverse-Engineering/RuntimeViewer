#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerCore

/// What the toolbar's runtime source picker lists when it opens: the sources a window can move to,
/// under one header per host, the one the window is on checked, and the dependency caches the
/// window's offline file can read its dependencies from.
///
/// The window's view model works it out from the engine manager's sections, as it worked out the
/// pop-up menu this picker replaced; `RuntimeSourcePopoverAdapter` turns it into the popover's rows.
public struct RuntimeSourcePickerContent: Equatable {
    /// One source the window can move to — an engine.
    public struct Source: Equatable {
        /// The engine's identifier, which the window's view model switches to.
        public let engineIdentifier: String

        public let title: String

        public let image: NSImage?

        /// Whether the window is on this source: its row is checked.
        public let isCurrent: Bool

        /// Whether the source can be chosen. Only the source the window was on before its engine
        /// went away cannot.
        public let isEnabled: Bool

        public init(engineIdentifier: String, title: String, image: NSImage?, isCurrent: Bool, isEnabled: Bool = true) {
            self.engineIdentifier = engineIdentifier
            self.title = title
            self.image = image
            self.isCurrent = isCurrent
            self.isEnabled = isEnabled
        }
    }

    /// The sources of one host, under the host's name.
    public struct Section: Equatable {
        public let title: String

        public let sources: [Source]

        public init(title: String, sources: [Source]) {
            self.title = title
            self.sources = sources
        }
    }

    /// A dependency cache the window's offline file can be paired with.
    public struct DependencyCacheChoice: Equatable {
        public let title: String

        /// The cache, or `nil` for reading the file alone.
        public let dependencyCache: RuntimeOfflineFile.DependencyCache?

        /// Whether the file reads its dependencies from it now.
        public let isCurrent: Bool

        public init(title: String, dependencyCache: RuntimeOfflineFile.DependencyCache?, isCurrent: Bool) {
            self.title = title
            self.dependencyCache = dependencyCache
            self.isCurrent = isCurrent
        }
    }

    /// The source the window is on, listed above the sections while its engine is gone — checked,
    /// and not a choice.
    public var disconnectedSource: Source?

    public var sections: [Section]

    /// The caches the window's offline file can read its dependencies from — empty unless the window
    /// is on an offline engine that reads a Mach-O file or a bundle.
    public var dependencyCacheChoices: [DependencyCacheChoice]

    public init(disconnectedSource: Source? = nil, sections: [Section], dependencyCacheChoices: [DependencyCacheChoice] = []) {
        self.disconnectedSource = disconnectedSource
        self.sections = sections
        self.dependencyCacheChoices = dependencyCacheChoices
    }

    /// Nothing to list: no engine is known yet.
    public static let empty = RuntimeSourcePickerContent(sections: [])
}

#endif
