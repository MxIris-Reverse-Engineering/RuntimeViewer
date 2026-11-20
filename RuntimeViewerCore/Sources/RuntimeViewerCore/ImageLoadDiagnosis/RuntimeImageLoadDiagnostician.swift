import Foundation
import MachO
import MachOKit

/// Retraces dyld's search for an image that failed to load, from inside the
/// process that tried: the chain of dependencies down to the one that failed,
/// every place the rpath stack sent dyld to look for it, why there, and
/// whether loading some images first would let the load through.
///
/// The images on the chain are read from disk — the one that failed was never
/// mapped — and an image dyld already loaded, or one in the shared cache,
/// counts as found. The search follows dyld-1323: a dependency's `@rpath/`
/// load name is first matched against the install names of the images already
/// loaded, then expanded with every `LC_RPATH` on the load chain, newest link
/// first — the loading image, each image that loaded it, the image that called
/// `dlopen`, the main executable. Weak, lazy and delay-init dependencies are
/// skipped, as dyld lets them be missing.
struct RuntimeImageLoadDiagnostician: Sendable {
    /// What the search depends on in the process that tried.
    struct Environment: Sendable {
        /// The executable `@executable_path` expands against.
        var mainExecutablePath: String
        /// The image that called `dlopen`, whose rpaths come before the main
        /// executable's: the image holding RuntimeViewerCore.
        var dlopenCallerImagePath: String
        var isSharedCacheImage: @Sendable (String) -> Bool
        /// The images loaded now, by install name; dyld matches an `@rpath/`
        /// load name against these before it searches.
        var loadedImagePathsByInstallName: @Sendable () -> [String: String]
        /// The CPU of the process, which picks the slice of a fat image.
        var cpuType: Int32
        var cpuSubtype: Int32
        var operatingSystemVersion: String

        var processArchitecture: String {
            RuntimeImageLoadDiagnostician.architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype)
        }

        /// This process, as dyld sees it.
        static func currentProcess() -> Environment {
            let header = UnsafeRawPointer(#dsohandle).load(as: mach_header.self)
            return Environment(
                mainExecutablePath: DyldUtilities.mainExecutablePath(),
                dlopenCallerImagePath: DyldUtilities.hostingImagePath() ?? DyldUtilities.mainExecutablePath(),
                isSharedCacheImage: { DyldUtilities.isInDyldSharedCache($0) },
                loadedImagePathsByInstallName: {
                    var pathsByInstallName: [String: String] = [:]
                    for index in 0 ..< _dyld_image_count() {
                        guard let header = _dyld_get_image_header(index),
                              let name = _dyld_get_image_name(index)
                        else { continue }
                        guard let installName = MachOImage(ptr: header).path else { continue }
                        pathsByInstallName[installName] = String(cString: name)
                    }
                    return pathsByInstallName
                },
                cpuType: header.cputype,
                cpuSubtype: header.cpusubtype,
                operatingSystemVersion: RuntimeImageLoadDiagnostician.operatingSystemVersionDescription()
            )
        }
    }

    let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// Diagnoses the failed load of the image at `imagePath`, which dyld
    /// refused with `dyldMessage`. A `hostApplicationPath` stands in for the
    /// main executable, and `searchPaths` are searched after the rpath stack,
    /// when the diagnosis works out what to load first.
    func diagnose(
        imageAt imagePath: String,
        dyldMessage: String,
        hostApplicationPath: String? = nil,
        searchPaths: [String] = []
    ) -> RuntimeImageLoadDiagnosis {
        let message = DyldLoadFailureMessage(parsing: dyldMessage)
        let loadedImagePathsByInstallName = environment.loadedImagePathsByInstallName()
        let realContext = SearchContext(
            mainExecutablePath: environment.mainExecutablePath,
            searchPaths: [],
            loadedImagePathsByInstallName: loadedImagePathsByInstallName
        )

        var diagnosis = RuntimeImageLoadDiagnosis(
            imagePath: imagePath,
            dyldMessage: dyldMessage,
            failure: message.failure,
            dependencyChain: [],
            rpathSearches: [],
            triedPaths: message.triedPaths,
            notes: [],
            remedy: nil,
            processArchitecture: environment.processArchitecture,
            operatingSystemVersion: environment.operatingSystemVersion,
            isFromMessageOnly: false
        )

        if let root = loadCommands(ofImageAt: imagePath), !root.isCompatible {
            diagnosis.notes.append(.init(kind: .architectureMismatch, imagePath: imagePath, architectures: root.architectures))
        }

        let failures = unresolvedEdges(from: imagePath, in: realContext)
        let chosenFailure = failures.first { failure in
            guard let lastLink = failure.chain.last else { return false }
            let matchesLoadName = message.failure.missingInstallName.map { $0 == lastLink.installName } ?? true
            let matchesLoader = message.failure.referencingImagePath.map { Self.isSameFile($0, lastLink.imagePath) } ?? true
            return matchesLoadName && matchesLoader
        } ?? failures.first

        if let chosenFailure {
            diagnosis.dependencyChain = chosenFailure.chain
            diagnosis.rpathSearches = chosenFailure.attempts.compactMap { attempt in
                guard let entry = attempt.entry else { return nil }
                return .init(
                    ownerImagePath: entry.ownerImagePath,
                    role: entry.role,
                    rpath: entry.rpath,
                    candidatePath: attempt.candidatePath,
                    outcome: attempt.exists ? .found : .noSuchFile
                )
            }
            if let hostNote = chosenFailure.attempts.lazy.compactMap(\.entry).first(where: { entry in
                entry.role == .loader && entry.rpath.hasPrefix("@executable_path")
            }) {
                diagnosis.notes.append(.init(kind: .rpathExpectsHostExecutable, imagePath: hostNote.ownerImagePath, rpath: hostNote.rpath))
            }
        } else if let referencingImagePath = message.failure.referencingImagePath,
                  let missingInstallName = message.failure.missingInstallName {
            diagnosis.dependencyChain = [.init(imagePath: referencingImagePath, installName: missingInstallName, resolvedPath: nil)]
        }

        if message.failure.kind == .symbolNotFound, let expectedInImagePath = message.failure.expectedInImagePath {
            diagnosis.notes.append(.init(kind: .symbolMissingFromImage, imagePath: expectedInImagePath))
        }

        if message.failure.kind == .imageNotFound, !failures.isEmpty {
            diagnosis.remedy = remedy(
                forImageAt: imagePath,
                hostApplicationPath: hostApplicationPath,
                searchPaths: searchPaths,
                loadedImagePathsByInstallName: loadedImagePathsByInstallName
            )
            if let remedy = diagnosis.remedy, let hostApplicationPath = remedy.hostApplicationPath {
                let frameworksDirectory = hostApplicationPath + "/Contents/Frameworks/"
                if let dependencyInHost = remedy.imagePathsToLoadFirst.first(where: { $0.hasPrefix(frameworksDirectory) }) {
                    diagnosis.notes.append(.init(kind: .dependencyInHostApplication, imagePath: dependencyInHost, hostApplicationPath: hostApplicationPath))
                }
            }
        }

        return diagnosis
    }

    // MARK: - Remedy

    /// What to load first so that the image at `imagePath` loads: every image
    /// of its dependency closure that is not loaded yet, dependencies first,
    /// found by searching as if `hostApplicationPath` — given, or else the app
    /// the image is in — were the main executable and `searchPaths` were more
    /// rpaths. `nil` when that still leaves a dependency unresolved, or when a
    /// dependency's load name starts at `@executable_path`: dyld matches only
    /// `@rpath/` load names against loaded images, so loading it first would
    /// not help.
    private func remedy(
        forImageAt imagePath: String,
        hostApplicationPath: String?,
        searchPaths: [String],
        loadedImagePathsByInstallName: [String: String]
    ) -> RuntimeImageLoadDiagnosis.Remedy? {
        var hostCandidates: [String?] = []
        if let hostApplicationPath { hostCandidates.append(hostApplicationPath) }
        if let enclosingApplication = Self.enclosingApplicationPath(of: imagePath), enclosingApplication != hostApplicationPath {
            hostCandidates.append(enclosingApplication)
        }
        if !searchPaths.isEmpty || hostCandidates.isEmpty { hostCandidates.append(nil) }

        for hostCandidate in hostCandidates {
            let mainExecutablePath = hostCandidate.flatMap(Self.executablePath(ofApplicationAt:)) ?? environment.mainExecutablePath
            if hostCandidate != nil, mainExecutablePath == environment.mainExecutablePath { continue }
            let context = SearchContext(
                mainExecutablePath: mainExecutablePath,
                searchPaths: searchPaths,
                loadedImagePathsByInstallName: loadedImagePathsByInstallName
            )
            guard let imagesToLoadFirst = closureToLoad(from: imagePath, in: context), !imagesToLoadFirst.isEmpty else { continue }
            return .init(hostApplicationPath: hostCandidate, searchPaths: searchPaths, imagePathsToLoadFirst: imagesToLoadFirst)
        }
        return nil
    }

    /// The images of the dependency closure of `rootPath` that are not loaded
    /// yet, in post-order (dependencies first), without the root; `nil` when a
    /// required dependency stays unresolved or needs `@executable_path`.
    private func closureToLoad(from rootPath: String, in context: SearchContext) -> [String]? {
        var visited: Set<String> = [Self.canonicalPath(rootPath)]
        var order: [String] = []
        var isLoadable = true

        func visit(_ imagePath: String, loaders: [String]) {
            guard isLoadable, let commands = loadCommands(ofImageAt: imagePath), commands.isCompatible else {
                isLoadable = false
                return
            }
            let stack = rpathStack(forDependenciesOf: imagePath, loaders: loaders, context: context)
            for dependency in commands.dependencies where !dependency.mayBeMissing {
                guard isLoadable else { return }
                if context.loadedImagePathsByInstallName[dependency.installName] != nil { continue }
                let resolution = resolver.resolution(
                    of: dependency.installName,
                    loadedBy: imagePath,
                    rpathStack: stack,
                    mainExecutablePath: context.mainExecutablePath
                )
                guard let resolvedPath = resolution.resolvedPath else {
                    isLoadable = false
                    return
                }
                if environment.isSharedCacheImage(resolvedPath) { continue }
                let canonical = Self.canonicalPath(resolvedPath)
                guard !visited.contains(canonical) else { continue }
                visited.insert(canonical)
                if dependency.installName.hasPrefix("@executable_path/") {
                    isLoadable = false
                    return
                }
                visit(resolvedPath, loaders: [imagePath] + loaders)
                order.append(resolvedPath)
            }
        }

        visit(rootPath, loaders: [])
        return isLoadable ? order : nil
    }

    // MARK: - Walking the Dependencies

    struct UnresolvedEdge: Sendable {
        var chain: [RuntimeImageLoadDiagnosis.ChainLink]
        var attempts: [DylibPathResolver.Attempt]
    }

    /// Every required dependency edge under `rootPath` that does not resolve,
    /// in dyld's order (depth first, in load command order), each with the
    /// chain from the root and the places it was looked for. Does not descend
    /// below an edge that failed, nor into the shared cache or loaded images.
    func unresolvedEdges(from rootPath: String, in context: SearchContext, limit: Int = 32) -> [UnresolvedEdge] {
        var visited: Set<String> = [Self.canonicalPath(rootPath)]
        var failures: [UnresolvedEdge] = []

        func visit(_ imagePath: String, loaders: [String], chain: [RuntimeImageLoadDiagnosis.ChainLink]) {
            guard failures.count < limit, let commands = loadCommands(ofImageAt: imagePath), commands.isCompatible else { return }
            let stack = rpathStack(forDependenciesOf: imagePath, loaders: loaders, context: context)
            for dependency in commands.dependencies where !dependency.mayBeMissing {
                guard failures.count < limit else { return }
                if context.loadedImagePathsByInstallName[dependency.installName] != nil { continue }
                let resolution = resolver.resolution(
                    of: dependency.installName,
                    loadedBy: imagePath,
                    rpathStack: stack,
                    mainExecutablePath: context.mainExecutablePath
                )
                let link = RuntimeImageLoadDiagnosis.ChainLink(
                    imagePath: imagePath,
                    installName: dependency.installName,
                    resolvedPath: resolution.resolvedPath
                )
                guard let resolvedPath = resolution.resolvedPath else {
                    failures.append(UnresolvedEdge(chain: chain + [link], attempts: resolution.attempts))
                    continue
                }
                if environment.isSharedCacheImage(resolvedPath) { continue }
                let canonical = Self.canonicalPath(resolvedPath)
                guard !visited.contains(canonical) else { continue }
                visited.insert(canonical)
                visit(resolvedPath, loaders: [imagePath] + loaders, chain: chain + [link])
            }
        }

        visit(rootPath, loaders: [], chain: [])
        return failures
    }

    /// dyld's rpath stack for the dependencies of `imagePath`, in search
    /// order: its own rpaths, those of each image that loaded it (`loaders`,
    /// newest first), the `dlopen` caller's, the main executable's — then
    /// `context.searchPaths`.
    private func rpathStack(
        forDependenciesOf imagePath: String,
        loaders: [String],
        context: SearchContext
    ) -> [DylibPathResolver.RpathStackEntry] {
        var stack: [DylibPathResolver.RpathStackEntry] = []
        for loaderPath in [imagePath] + loaders {
            for rpath in loadCommands(ofImageAt: loaderPath)?.rpaths ?? [] {
                stack.append(.init(rpath: rpath, ownerImagePath: loaderPath, role: .loader))
            }
        }
        for rpath in loadCommands(ofImageAt: environment.dlopenCallerImagePath)?.rpaths ?? [] {
            stack.append(.init(rpath: rpath, ownerImagePath: environment.dlopenCallerImagePath, role: .dlopenCaller))
        }
        for rpath in loadCommands(ofImageAt: context.mainExecutablePath)?.rpaths ?? [] {
            stack.append(.init(rpath: rpath, ownerImagePath: context.mainExecutablePath, role: .mainExecutable))
        }
        for searchPath in context.searchPaths {
            stack.append(.init(rpath: searchPath, ownerImagePath: searchPath, role: .searchPath))
        }
        return stack
    }

    private var resolver: DylibPathResolver {
        DylibPathResolver(isSharedCacheImage: environment.isSharedCacheImage)
    }

    // MARK: - Reading Images

    struct SearchContext: Sendable {
        var mainExecutablePath: String
        var searchPaths: [String]
        var loadedImagePathsByInstallName: [String: String]
    }

    struct Dependency: Sendable, Hashable {
        var installName: String
        /// Weak, lazy or delay-init: dyld lets it be missing.
        var mayBeMissing: Bool
    }

    struct LoadCommands: Sendable {
        var rpaths: [String]
        var dependencies: [Dependency]
        /// Every architecture the file has a slice for.
        var architectures: [String]
        /// Whether one of them is this process's.
        var isCompatible: Bool
    }

    /// The load commands of the slice of the file at `imagePath` this process
    /// would load; `nil` when the file cannot be read as Mach-O.
    func loadCommands(ofImageAt imagePath: String) -> LoadCommands? {
        guard let file = try? File.loadFromFile(url: URL(fileURLWithPath: imagePath)) else { return nil }
        let slices: [MachOFile]
        switch file {
        case .machO(let machOFile):
            slices = [machOFile]
        case .fat(let fatFile):
            slices = (try? fatFile.machOFiles()) ?? []
        }
        let subtypeMask = Int32(bitPattern: 0x00FF_FFFF)
        let architectures = slices.map {
            Self.architectureName(cpuType: $0.header.layout.cputype, cpuSubtype: $0.header.layout.cpusubtype)
        }
        let sameType = slices.filter { $0.header.layout.cputype == environment.cpuType }
        let chosen = sameType.first { $0.header.layout.cpusubtype & subtypeMask == environment.cpuSubtype & subtypeMask }
            ?? sameType.first
        guard let chosen else {
            return LoadCommands(rpaths: [], dependencies: [], architectures: architectures, isCompatible: false)
        }
        let dependencies = chosen.dependencies.map { dependency in
            Dependency(
                installName: dependency.dylib.name,
                mayBeMissing: dependency.type == .weakLoad
                    || dependency.type == .lazyLoad
                    || dependency.useFlags.contains(.delayed_init)
            )
        }
        return LoadCommands(rpaths: chosen.rpaths, dependencies: dependencies, architectures: architectures, isCompatible: true)
    }

    // MARK: - Paths and Names

    /// The app bundle `imagePath` lies in — the nearest `.app` on its path.
    static func enclosingApplicationPath(of imagePath: String) -> String? {
        var components = (imagePath as NSString).pathComponents
        while let last = components.last {
            if last.hasSuffix(".app") {
                return NSString.path(withComponents: components)
            }
            components.removeLast()
        }
        return nil
    }

    /// The main executable of the app at `applicationPath`: its bundle's, or
    /// `Contents/MacOS/<name>` when the bundle does not say.
    static func executablePath(ofApplicationAt applicationPath: String) -> String? {
        if let executablePath = Bundle(path: applicationPath)?.executablePath {
            return executablePath
        }
        let name = ((applicationPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let fallback = applicationPath + "/Contents/MacOS/" + name
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    static func canonicalPath(_ path: String) -> String {
        DyldUtilities.pathAsDyldListsIt(path)
    }

    static func isSameFile(_ firstPath: String, _ secondPath: String) -> Bool {
        firstPath == secondPath || canonicalPath(firstPath) == canonicalPath(secondPath)
    }

    /// `arm64e`, `arm64`, `x86_64`, or the raw numbers for anything else.
    static func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & Int32(bitPattern: 0x00FF_FFFF)
        switch cpuType {
        case 0x0100_000C:
            return subtype == 2 ? "arm64e" : "arm64"
        case 0x0100_0007:
            return "x86_64"
        default:
            return "cputype \(cpuType), subtype \(subtype)"
        }
    }

    static func operatingSystemVersionDescription() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platform: String
        #if targetEnvironment(macCatalyst)
        platform = "Mac Catalyst"
        #elseif os(macOS)
        platform = "macOS"
        #elseif os(iOS)
        platform = "iOS"
        #elseif os(tvOS)
        platform = "tvOS"
        #elseif os(watchOS)
        platform = "watchOS"
        #elseif os(visionOS)
        platform = "visionOS"
        #else
        platform = "OS"
        #endif
        let patch = version.patchVersion == 0 ? "" : ".\(version.patchVersion)"
        return "\(platform) \(version.majorVersion).\(version.minorVersion)\(patch)"
    }
}
