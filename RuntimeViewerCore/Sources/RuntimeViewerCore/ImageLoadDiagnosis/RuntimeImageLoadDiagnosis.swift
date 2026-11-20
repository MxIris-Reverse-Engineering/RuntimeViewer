import Foundation

/// Why dyld refused to load an image, worked out in the process that tried.
///
/// dyld's own message names the dependency it could not find and the paths it
/// tried, but not where those paths came from. A framework of a third-party app
/// usually carries an rpath such as `@executable_path/../Frameworks`, written
/// for its app's executable; loaded anywhere else, `@executable_path` is that
/// other process's executable and the dependency is never found. This value
/// says so: the chain of dependencies down to the one that failed, every place
/// dyld's rpath stack sent it to look, a sentence on why, and — when loading
/// some images first by their absolute paths would let the load through — what
/// to load.
///
/// It crosses connections, so every kind and role is an open struct rather
/// than an enum: a later version may name one an earlier app has never heard
/// of, and the value must still decode.
public struct RuntimeImageLoadDiagnosis: Codable, Sendable, Hashable {
    /// What dyld said went wrong.
    public struct Failure: Codable, Sendable, Hashable {
        public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// `Library not loaded`, or the requested image itself missing.
            public static let imageNotFound = Kind(rawValue: "imageNotFound")
            /// `Symbol not found`: an image exists, without a symbol another needs.
            public static let symbolNotFound = Kind(rawValue: "symbolNotFound")
            /// An image exists, with no slice this process can run.
            public static let incompatibleImage = Kind(rawValue: "incompatibleImage")
            /// A message none of the above reads; only its text is shown.
            public static let unrecognized = Kind(rawValue: "unrecognized")
        }

        public var kind: Kind
        /// The load name dyld could not resolve, or the image it could not use.
        public var missingInstallName: String?
        public var symbolName: String?
        /// The image whose load command or symbol reference failed.
        public var referencingImagePath: String?
        /// For a missing symbol, the image it was expected in.
        public var expectedInImagePath: String?
        /// dyld's own reason, for an image it found and could not use.
        public var reason: String?

        public init(
            kind: Kind,
            missingInstallName: String? = nil,
            symbolName: String? = nil,
            referencingImagePath: String? = nil,
            expectedInImagePath: String? = nil,
            reason: String? = nil
        ) {
            self.kind = kind
            self.missingInstallName = missingInstallName
            self.symbolName = symbolName
            self.referencingImagePath = referencingImagePath
            self.expectedInImagePath = expectedInImagePath
            self.reason = reason
        }
    }

    /// One edge of the dependency chain from the requested image to the failure:
    /// `imagePath` links `installName`.
    public struct ChainLink: Codable, Sendable, Hashable {
        public var imagePath: String
        public var installName: String
        /// The path the load name resolved to; `nil` on the edge that failed.
        public var resolvedPath: String?

        public var isResolved: Bool { resolvedPath != nil }

        public init(imagePath: String, installName: String, resolvedPath: String?) {
            self.imagePath = imagePath
            self.installName = installName
            self.resolvedPath = resolvedPath
        }
    }

    /// One place dyld looked for a missing `@rpath/` image: one `LC_RPATH` of
    /// one image on the rpath stack, expanded.
    public struct RpathSearch: Codable, Sendable, Hashable {
        /// Whose `LC_RPATH` it is.
        public struct Role: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// The image that links the missing one, or an image that loaded it.
            public static let loader = Role(rawValue: "loader")
            /// The image that called `dlopen`.
            public static let dlopenCaller = Role(rawValue: "dlopenCaller")
            /// The process's main executable.
            public static let mainExecutable = Role(rawValue: "mainExecutable")
            /// A directory the user added, searched after the stack.
            public static let searchPath = Role(rawValue: "searchPath")
        }

        public struct Outcome: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            public static let noSuchFile = Outcome(rawValue: "noSuchFile")
            public static let found = Outcome(rawValue: "found")
        }

        public var ownerImagePath: String
        public var role: Role
        /// The `LC_RPATH` as written.
        public var rpath: String
        /// The rpath expanded and joined with the rest of the load name.
        public var candidatePath: String
        public var outcome: Outcome

        public init(ownerImagePath: String, role: Role, rpath: String, candidatePath: String, outcome: Outcome) {
            self.ownerImagePath = ownerImagePath
            self.role = role
            self.rpath = rpath
            self.candidatePath = candidatePath
            self.outcome = outcome
        }
    }

    /// One path from dyld's own `tried:` list, with its reason.
    public struct TriedPath: Codable, Sendable, Hashable {
        public var path: String
        public var reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// A sentence the diagnosis page shows: why the search went where it went.
    public struct Note: Codable, Sendable, Hashable {
        public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
            public let rawValue: String

            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// `imagePath` carries `rpath`, which starts at `@executable_path`
            /// and so was written for a host app's executable — here it expands
            /// against this process's.
            public static let rpathExpectsHostExecutable = Kind(rawValue: "rpathExpectsHostExecutable")
            /// The missing image, `imagePath`, is in the Frameworks directory of
            /// `hostApplicationPath`.
            public static let dependencyInHostApplication = Kind(rawValue: "dependencyInHostApplication")
            /// The image `imagePath` exists but lacks a symbol: another version of it.
            public static let symbolMissingFromImage = Kind(rawValue: "symbolMissingFromImage")
            /// `imagePath` has only `architectures`, none of which this process runs.
            public static let architectureMismatch = Kind(rawValue: "architectureMismatch")
        }

        public var kind: Kind
        public var imagePath: String?
        public var rpath: String?
        public var hostApplicationPath: String?
        public var architectures: [String]?

        public init(
            kind: Kind,
            imagePath: String? = nil,
            rpath: String? = nil,
            hostApplicationPath: String? = nil,
            architectures: [String]? = nil
        ) {
            self.kind = kind
            self.imagePath = imagePath
            self.rpath = rpath
            self.hostApplicationPath = hostApplicationPath
            self.architectures = architectures
        }
    }

    /// Images to load by their absolute paths, dependencies first, before the
    /// requested image is tried again. dyld matches an `@rpath/` load name
    /// against the install names of the images already loaded before it
    /// searches, so once these are in, the requested image finds them.
    public struct Remedy: Codable, Sendable, Hashable {
        /// The app whose executable stood in for this process's, if any.
        public var hostApplicationPath: String?
        /// The directories searched after the rpath stack.
        public var searchPaths: [String]
        public var imagePathsToLoadFirst: [String]

        public init(hostApplicationPath: String?, searchPaths: [String], imagePathsToLoadFirst: [String]) {
            self.hostApplicationPath = hostApplicationPath
            self.searchPaths = searchPaths
            self.imagePathsToLoadFirst = imagePathsToLoadFirst
        }
    }

    /// The image the load was asked for.
    public var imagePath: String
    /// dyld's message, whole.
    public var dyldMessage: String
    public var failure: Failure
    public var dependencyChain: [ChainLink]
    public var rpathSearches: [RpathSearch]
    public var triedPaths: [TriedPath]
    public var notes: [Note]
    public var remedy: Remedy?
    /// The architecture and system of the process that tried, which the search
    /// depends on.
    public var processArchitecture: String?
    public var operatingSystemVersion: String?
    /// True when only dyld's message was available: the process that tried is
    /// of an earlier version and could not work anything out itself.
    public var isFromMessageOnly: Bool

    public init(
        imagePath: String,
        dyldMessage: String,
        failure: Failure,
        dependencyChain: [ChainLink],
        rpathSearches: [RpathSearch],
        triedPaths: [TriedPath],
        notes: [Note],
        remedy: Remedy?,
        processArchitecture: String?,
        operatingSystemVersion: String?,
        isFromMessageOnly: Bool
    ) {
        self.imagePath = imagePath
        self.dyldMessage = dyldMessage
        self.failure = failure
        self.dependencyChain = dependencyChain
        self.rpathSearches = rpathSearches
        self.triedPaths = triedPaths
        self.notes = notes
        self.remedy = remedy
        self.processArchitecture = processArchitecture
        self.operatingSystemVersion = operatingSystemVersion
        self.isFromMessageOnly = isFromMessageOnly
    }

    /// What can be read from dyld's message alone: the diagnosis of a failure
    /// that a process of an earlier version reported as text.
    public init(dyldMessage: String, imagePath: String) {
        let message = DyldLoadFailureMessage(parsing: dyldMessage)
        var dependencyChain: [ChainLink] = []
        if let referencingImagePath = message.failure.referencingImagePath,
           let missingInstallName = message.failure.missingInstallName {
            dependencyChain = [ChainLink(imagePath: referencingImagePath, installName: missingInstallName, resolvedPath: nil)]
        }
        self.init(
            imagePath: imagePath,
            dyldMessage: dyldMessage,
            failure: message.failure,
            dependencyChain: dependencyChain,
            rpathSearches: [],
            triedPaths: message.triedPaths,
            notes: [],
            remedy: nil,
            processArchitecture: nil,
            operatingSystemVersion: nil,
            isFromMessageOnly: true
        )
    }
}

extension RuntimeImageLoadDiagnosis {
    /// The folder the image at `imagePath` sits in with the frameworks it came
    /// with: the one holding the nearest `.framework` bundle on its path, or the
    /// image's own folder when it is in no framework.
    ///
    /// Frameworks copied out of an app keep their siblings there, while their
    /// rpaths still point into the app (`@executable_path/../Frameworks`), so
    /// the remedy searches this folder after the folders the user added.
    public static func folderHoldingImage(at imagePath: String) -> String {
        var components = (imagePath as NSString).pathComponents
        while let last = components.last {
            components.removeLast()
            if last.hasSuffix(".framework"), !components.isEmpty {
                return NSString.path(withComponents: components)
            }
        }
        return (imagePath as NSString).deletingLastPathComponent
    }
}
