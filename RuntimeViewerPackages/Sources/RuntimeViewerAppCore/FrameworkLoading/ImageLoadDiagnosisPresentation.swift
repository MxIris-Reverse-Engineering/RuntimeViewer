import Foundation
import RuntimeViewerCore

/// What the diagnosis page shows for a refused load, as text: a title and a
/// sentence saying what went wrong, tags, the remedy on offer, the dependency
/// chain, where dyld looked for the missing image and why there, dyld's own
/// list of what it tried, its message, and all of it again as plain text to
/// copy. Worked out from a `RuntimeImageLoadDiagnosis`; the view lays it out.
public struct ImageLoadDiagnosisPresentation: Equatable, Sendable {
    public struct ChainItem: Equatable, Sendable {
        public var name: String
        public var isMissing: Bool
    }

    public struct RpathRow: Equatable, Sendable {
        /// The image whose rpath it is, and what that image is to the load.
        public var ownerName: String
        public var ownerRole: String
        public var rpath: String
        public var candidatePath: String
        public var outcome: String
    }

    public struct TriedRow: Equatable, Sendable {
        public var path: String
        public var reason: String
    }

    public var title: String
    public var summary: String
    public var tags: [String]
    /// What the remedy would do, when there is one.
    public var remedyExplanation: String?
    /// The remedy button's title, when there is a remedy.
    public var remedyTitle: String?
    public var chain: [ChainItem]
    public var rpathRows: [RpathRow]
    /// Why the search went where it went.
    public var explanations: [String]
    public var triedRows: [TriedRow]
    public var dyldMessage: String
    /// The image the load was for, which Show in Finder reveals.
    public var imagePath: String
    public var copyText: String

    public init(diagnosis: RuntimeImageLoadDiagnosis, frameworkName: String) {
        let failure = diagnosis.failure
        title = "\(frameworkName) couldn't be loaded"
        summary = Self.summary(of: diagnosis)
        tags = Self.tags(of: diagnosis)
        imagePath = diagnosis.imagePath
        dyldMessage = diagnosis.dyldMessage

        if let remedy = diagnosis.remedy {
            let missingName = failure.missingInstallName.map(Self.displayName(ofImageAt:)) ?? "What it needs"
            let rootName = Self.displayName(ofImageAt: diagnosis.imagePath)
            if let hostApplicationPath = remedy.hostApplicationPath {
                let hostName = Self.applicationName(at: hostApplicationPath)
                let isInHostFrameworks = diagnosis.notes.contains { $0.kind == .dependencyInHostApplication }
                let place = isInHostFrameworks ? "is in \(hostApplicationPath)/Contents/Frameworks" : "is found when \(hostName) loads \(rootName)"
                var explanation = "\(missingName) \(place). \(rootName) expects \(hostName) to load it"
                if diagnosis.notes.contains(where: { $0.kind == .rpathExpectsHostExecutable }) {
                    explanation += ": its rpaths start at @executable_path, which here is this instance, not \(hostName)."
                } else {
                    explanation += "."
                }
                remedyExplanation = explanation
                remedyTitle = "Load \(hostName)'s Frameworks and Retry"
            } else {
                let imageFolder = RuntimeImageLoadDiagnosis.folderHoldingImage(at: diagnosis.imagePath)
                let isBesideTheImage = !remedy.imagePathsToLoadFirst.isEmpty
                    && remedy.imagePathsToLoadFirst.allSatisfy { $0.hasPrefix(imageFolder + "/") }
                let place = isBesideTheImage ? "is next to \(rootName) in \(imageFolder)" : "is in the folders you added"
                remedyExplanation = "\(missingName) \(place). Loading what \(rootName) needs from there first lets it load."
                let count = remedy.imagePathsToLoadFirst.count
                remedyTitle = count == 1 ? "Load 1 Image and Retry" : "Load \(count) Images and Retry"
            }
        } else {
            remedyExplanation = nil
            remedyTitle = nil
        }

        var chain: [ChainItem] = []
        if let firstLink = diagnosis.dependencyChain.first {
            chain.append(ChainItem(name: Self.displayName(ofImageAt: firstLink.imagePath), isMissing: false))
            for link in diagnosis.dependencyChain {
                chain.append(ChainItem(
                    name: Self.displayName(ofImageAt: link.resolvedPath ?? link.installName),
                    isMissing: !link.isResolved
                ))
            }
        }
        self.chain = chain

        rpathRows = diagnosis.rpathSearches.map { search in
            RpathRow(
                ownerName: Self.displayName(ofImageAt: search.ownerImagePath),
                ownerRole: Self.description(of: search.role),
                rpath: search.rpath,
                candidatePath: search.candidatePath,
                outcome: search.outcome == .found ? "found" : "no such file"
            )
        }
        explanations = diagnosis.notes.compactMap { Self.explanation(of: $0, in: diagnosis) }
        triedRows = diagnosis.triedPaths.map { TriedRow(path: $0.path, reason: $0.reason) }

        copyText = Self.copyText(
            title: title,
            summary: summary,
            tags: tags,
            remedyExplanation: remedyExplanation,
            chain: chain,
            rpathRows: rpathRows,
            explanations: explanations,
            triedRows: triedRows,
            dyldMessage: dyldMessage
        )
    }

    // MARK: - Sentences

    private static func summary(of diagnosis: RuntimeImageLoadDiagnosis) -> String {
        let failure = diagnosis.failure
        switch failure.kind {
        case .imageNotFound:
            guard let missing = failure.missingInstallName else { break }
            if let referencing = failure.referencingImagePath {
                return "dyld couldn't find \(missing), which \(displayName(ofImageAt: referencing)) links."
            }
            return "dyld couldn't find \(missing)."
        case .symbolNotFound:
            let symbol = failure.symbolName ?? "a symbol"
            let referencing = failure.referencingImagePath.map(displayName(ofImageAt:)) ?? displayName(ofImageAt: diagnosis.imagePath)
            if let expectedIn = failure.expectedInImagePath {
                return "\(referencing) uses \(symbol), which \(displayName(ofImageAt: expectedIn)) doesn't export."
            }
            return "\(referencing) uses \(symbol), which no loaded image exports."
        case .incompatibleImage:
            let image = failure.missingInstallName.map(displayName(ofImageAt:)) ?? displayName(ofImageAt: diagnosis.imagePath)
            if let reason = failure.reason {
                return "\(image) can't run in this process: \(reason)."
            }
            return "\(image) can't run in this process."
        default:
            break
        }
        let firstLine = diagnosis.dyldMessage.components(separatedBy: "\n").first ?? diagnosis.dyldMessage
        return "dyld refused it: \(firstLine)"
    }

    private static func tags(of diagnosis: RuntimeImageLoadDiagnosis) -> [String] {
        var tags: [String] = []
        let failure = diagnosis.failure
        switch failure.kind {
        case .imageNotFound:
            tags.append(failure.missingInstallName?.hasPrefix("@rpath/") == true ? "Unresolved @rpath" : "Missing Image")
        case .symbolNotFound:
            tags.append("Missing Symbol")
        case .incompatibleImage:
            tags.append("Incompatible Image")
        default:
            tags.append("Load Failed")
        }
        switch (diagnosis.processArchitecture, diagnosis.operatingSystemVersion) {
        case (let architecture?, let system?):
            tags.append("\(architecture) · \(system)")
        case (let architecture?, nil):
            tags.append(architecture)
        case (nil, let system?):
            tags.append(system)
        case (nil, nil):
            break
        }
        tags.append(diagnosis.isFromMessageOnly
            ? "From dyld's message only: the process that tried runs an earlier version"
            : "Diagnosed in the process that tried the load")
        return tags
    }

    private static func explanation(of note: RuntimeImageLoadDiagnosis.Note, in diagnosis: RuntimeImageLoadDiagnosis) -> String? {
        switch note.kind {
        case .rpathExpectsHostExecutable:
            guard let imagePath = note.imagePath, let rpath = note.rpath else { return nil }
            let name = displayName(ofImageAt: imagePath)
            return "\(name)'s rpath \(rpath) is meant for the app \(name) belongs to. Loaded outside that app, @executable_path is this process's executable."
        case .symbolMissingFromImage:
            guard let imagePath = note.imagePath else { return nil }
            return "\(displayName(ofImageAt: imagePath)) is there, but a different version of it: it doesn't export what the image that links it expects."
        case .architectureMismatch:
            let name = displayName(ofImageAt: note.imagePath ?? diagnosis.imagePath)
            let architectures = (note.architectures ?? []).joined(separator: ", ")
            let processArchitecture = diagnosis.processArchitecture.map { ", and this process runs \($0)" } ?? ""
            return "\(name) has \(architectures.isEmpty ? "no slice" : "only \(architectures)")\(processArchitecture)."
        case .dependencyInHostApplication:
            return nil
        default:
            return nil
        }
    }

    private static func description(of role: RuntimeImageLoadDiagnosis.RpathSearch.Role) -> String {
        switch role {
        case .mainExecutable: "main executable"
        case .dlopenCaller: "image that called dlopen"
        case .loader: "loader"
        case .searchPath: "folder you added"
        default: role.rawValue
        }
    }

    private static func copyText(
        title: String,
        summary: String,
        tags: [String],
        remedyExplanation: String?,
        chain: [ChainItem],
        rpathRows: [RpathRow],
        explanations: [String],
        triedRows: [TriedRow],
        dyldMessage: String
    ) -> String {
        var lines = [title, summary, tags.joined(separator: " · ")]
        if let remedyExplanation {
            lines += ["", remedyExplanation]
        }
        if !chain.isEmpty {
            lines += ["", "Dependency chain: " + chain.map { $0.isMissing ? "\($0.name) (missing)" : $0.name }.joined(separator: " → ")]
        }
        if !rpathRows.isEmpty {
            lines += ["", "Where it looked:"]
            lines += rpathRows.map { "  \($0.ownerName) (\($0.ownerRole)) \($0.rpath) → \($0.candidatePath): \($0.outcome)" }
        }
        if !explanations.isEmpty {
            lines += [""] + explanations.map { "Why: \($0)" }
        }
        if !triedRows.isEmpty {
            lines += ["", "Paths dyld tried:"]
            lines += triedRows.map { "  \($0.path): \($0.reason)" }
        }
        lines += ["", "dyld message:", dyldMessage]
        return lines.joined(separator: "\n")
    }

    // MARK: - Names

    /// `Foo.framework` for anything inside a framework bundle, the file's name otherwise.
    static func displayName(ofImageAt path: String) -> String {
        let components = path.components(separatedBy: "/")
        if let framework = components.last(where: { $0.hasSuffix(".framework") }) {
            return framework
        }
        return components.last(where: { !$0.isEmpty }) ?? path
    }

    static func applicationName(at applicationPath: String) -> String {
        (applicationPath as NSString).lastPathComponent
    }
}
