import Foundation
import PackagePlugin

/// Runs `UpdatePackagesScript.sh` from Xcode: right-click RuntimeViewerPackages in the Project
/// navigator and choose UpdatePackages. Arguments typed into the command's sheet go to the script,
/// for example `--workspace Debug` or `--dry-run`. The script sits one level above this package.
///
/// Xcode runs command plugins in a sandbox that writes nothing but the plugin's own work
/// directory, and the script has to write the workspaces' `Package.resolved` and fetch Xcode's
/// own package mirrors — the ones Xcode 27 never fetches, which is why its Update to Latest
/// Package Versions fails. So the command works only with that sandbox switched off, once:
///
///     defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
///
/// and a restart of Xcode. Despite its name, that is the switch Xcode's SwiftPM reads for
/// command plugins: one flag set in `SPMWorkspace.init` decides both the manifest sandbox and the
/// `enableSandbox:` of its plugin script runners, so every manifest and every command plugin in
/// every project runs unsandboxed from then on. `IDEPackageSupportDisablePluginExecutionSandbox`
/// does not reach command plugins; it covers build-tool plugins only. Evidence:
/// `/Volumes/RE/Xcode/27.0/README.md`. Without the switch the command changes nothing and says
/// what to do.
@main
struct UpdatePackagesCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let repositoryDirectory = context.package.directoryURL.deletingLastPathComponent()
        let scriptPath = repositoryDirectory.appending(path: "UpdatePackagesScript.sh").path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            Diagnostics.error("UpdatePackagesScript.sh is missing from \(repositoryDirectory.path(percentEncoded: false))")
            return
        }
        guard Self.canWrite(to: repositoryDirectory) else {
            Diagnostics.error("""
                Xcode ran this command in its plugin sandbox, which cannot write the workspaces' Package.resolved \
                or Xcode's package mirrors, so nothing was changed. Run \
                `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`, \
                restart Xcode and run the command again — or run ./UpdatePackagesScript.sh in Terminal.
                """)
            return
        }

        // Xcode passes the targets picked in the command's sheet as --target options; the script
        // works on whole workspaces and would reject them.
        var argumentExtractor = ArgumentExtractor(arguments)
        _ = argumentExtractor.extractOption(named: "target")
        let scriptArguments = argumentExtractor.remainingArguments

        Diagnostics.progress("Updating the package pins of the RuntimeViewer workspaces")
        let exitStatus = try await Self.runScript(atPath: scriptPath, arguments: scriptArguments, in: repositoryDirectory)
        if exitStatus != 0 {
            Diagnostics.error("UpdatePackagesScript.sh exited with status \(exitStatus); the output above says why")
        }
    }

    /// Whether this process may write `directory`, which it may not inside Xcode's plugin sandbox.
    private static func canWrite(to directory: URL) -> Bool {
        let probePath = directory
            .appending(path: ".update-packages-probe-\(ProcessInfo.processInfo.processIdentifier)")
            .path(percentEncoded: false)
        guard FileManager.default.createFile(atPath: probePath, contents: Data()) else {
            return false
        }
        try? FileManager.default.removeItem(atPath: probePath)
        return true
    }

    /// Runs the script with /bin/bash, echoing its output as it arrives, and returns its exit status.
    private static func runScript(atPath scriptPath: String, arguments: [String], in directory: URL) async throws -> Int32 {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [scriptPath] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        // Only the script holds the write end from here on, so the read below ends when it exits.
        try? outputPipe.fileHandleForWriting.close()
        for try await line in outputPipe.fileHandleForReading.bytes.lines {
            print(line)
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
