#if os(macOS)

import Foundation

/// Frameworks built at test time with `clang`, laid out as a third-party app
/// lays out its own: an app whose frameworks link each other through `@rpath/`
/// and carry rpaths written for the app's executable.
///
/// Every name carries a random suffix. dyld matches an `@rpath/` load name
/// against the install names of the images already loaded before it searches,
/// so a `Bar` one test loaded into the test process would otherwise satisfy
/// another test's missing `Bar`.
enum ImageLoadFixtures {
    struct Framework {
        var name: String
        var bundlePath: String
        var binaryPath: String
        var installName: String
    }

    enum Placement {
        /// The app's `Contents/Frameworks`.
        case hostFrameworks
        /// The `Versions/A/Frameworks` of a framework built before it.
        case insideFramework(String)
        /// A directory outside the app.
        case outside(String)
    }

    struct FrameworkSpecification {
        var baseName: String
        var dependencies: [String] = []
        var rpaths: [String] = []
        var placement: Placement = .hostFrameworks
        var architecture = "arm64"
        /// Exports `<name>_extra`, which `usesExtraSymbolOf` of another framework calls.
        var exportsExtraSymbol = false
        var usesExtraSymbolOf: [String] = []
        /// Built again without `<name>_extra` once everything is linked, so a
        /// framework that calls it fails with `Symbol not found`.
        var losesExtraSymbolAfterLinking = false
    }

    struct HostApplication {
        var rootDirectory: URL
        var applicationPath: String
        var executablePath: String
        var outsideDirectories: [String: String]
        var frameworks: [String: Framework]

        func framework(_ baseName: String) -> Framework {
            frameworks[baseName]!
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case toolFailed(arguments: [String], output: String)

        var description: String {
            switch self {
            case .toolFailed(let arguments, let output):
                "xcrun \(arguments.joined(separator: " ")) failed: \(output)"
            }
        }
    }

    /// `Example<suffix>.app`, its executable (rpath `@executable_path/../Frameworks`)
    /// and `frameworks`, built in order — a framework's dependencies first.
    static func makeHostApplication(frameworks specifications: [FrameworkSpecification]) throws -> HostApplication {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewerImageLoadFixtures", isDirectory: true)
            .appendingPathComponent(suffix, isDirectory: true)
        let sourceDirectory = rootDirectory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        let applicationName = "Example\(suffix)"
        let applicationPath = rootDirectory.appendingPathComponent("\(applicationName).app").path
        let macOSDirectory = applicationPath + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macOSDirectory, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": applicationName,
            "CFBundleIdentifier": "com.RuntimeViewer.Tests.\(applicationName)",
            "CFBundlePackageType": "APPL",
        ]
        let infoPlistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try infoPlistData.write(to: URL(fileURLWithPath: applicationPath + "/Contents/Info.plist"))

        let mainSource = sourceDirectory.appendingPathComponent("main.c")
        try "int main(void) { return 0; }\n".write(to: mainSource, atomically: true, encoding: .utf8)
        let executablePath = macOSDirectory + "/" + applicationName
        try run(["clang", "-arch", "arm64", "-o", executablePath, mainSource.path, "-Wl,-rpath,@executable_path/../Frameworks"])

        var frameworks: [String: Framework] = [:]
        var outsideDirectories: [String: String] = [:]
        for specification in specifications {
            let name = specification.baseName + suffix
            let directory: String
            switch specification.placement {
            case .hostFrameworks:
                directory = applicationPath + "/Contents/Frameworks"
            case .insideFramework(let containerBaseName):
                directory = frameworks[containerBaseName]!.bundlePath + "/Versions/A/Frameworks"
            case .outside(let directoryName):
                directory = rootDirectory.appendingPathComponent(directoryName).path
                outsideDirectories[directoryName] = directory
            }
            let bundlePath = directory + "/\(name).framework"
            let versionDirectory = bundlePath + "/Versions/A"
            try FileManager.default.createDirectory(atPath: versionDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: bundlePath + "/Versions/Current", withDestinationPath: "A")
            try? FileManager.default.createSymbolicLink(atPath: bundlePath + "/\(name)", withDestinationPath: "Versions/Current/\(name)")
            let framework = Framework(
                name: name,
                bundlePath: bundlePath,
                binaryPath: versionDirectory + "/" + name,
                installName: "@rpath/\(name).framework/Versions/A/\(name)"
            )
            frameworks[specification.baseName] = framework
            try build(framework, specification: specification, suffix: suffix, withExtraSymbol: specification.exportsExtraSymbol, frameworks: frameworks, sourceDirectory: sourceDirectory)
        }
        for specification in specifications where specification.losesExtraSymbolAfterLinking {
            try build(frameworks[specification.baseName]!, specification: specification, suffix: suffix, withExtraSymbol: false, frameworks: frameworks, sourceDirectory: sourceDirectory)
        }

        return HostApplication(
            rootDirectory: rootDirectory,
            applicationPath: applicationPath,
            executablePath: executablePath,
            outsideDirectories: outsideDirectories,
            frameworks: frameworks
        )
    }

    private static func build(
        _ framework: Framework,
        specification: FrameworkSpecification,
        suffix: String,
        withExtraSymbol: Bool,
        frameworks: [String: Framework],
        sourceDirectory: URL
    ) throws {
        let dependencyNames = specification.dependencies.map { $0 + suffix }
        var source = dependencyNames.map { "extern int \($0)_value(void);\n" }.joined()
        let extraUsers = specification.usesExtraSymbolOf.map { $0 + suffix }
        source += extraUsers.map { "extern int \($0)_extra(void);\n" }.joined()
        let calls = (dependencyNames.map { "\($0)_value()" } + extraUsers.map { "\($0)_extra()" })
        source += "int \(framework.name)_value(void) { return 1\(calls.map { " + " + $0 }.joined()); }\n"
        if withExtraSymbol {
            source += "int \(framework.name)_extra(void) { return 2; }\n"
        }
        let sourceFile = sourceDirectory.appendingPathComponent("\(framework.name)-\(withExtraSymbol ? "full" : "reduced").c")
        try source.write(to: sourceFile, atomically: true, encoding: .utf8)

        var arguments = [
            "clang", "-dynamiclib", "-arch", specification.architecture,
            "-o", framework.binaryPath, sourceFile.path,
            "-install_name", framework.installName,
        ]
        let linkedNames = Set(specification.dependencies + specification.usesExtraSymbolOf)
        for dependency in linkedNames.sorted() {
            arguments.append(frameworks[dependency]!.binaryPath)
        }
        for rpath in specification.rpaths {
            arguments.append("-Wl,-rpath,\(rpath)")
        }
        try run(arguments)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.toolFailed(arguments: arguments, output: output)
        }
    }
}

#endif
