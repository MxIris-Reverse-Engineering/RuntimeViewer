import ArgumentParser
import Foundation

/// Options every subcommand accepts.
public struct GlobalOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: ArgumentHelp("Runtime source to inspect.", discussion: "local (default), catalyst, pid:<number>, process:<name>, engine:<identifier>. This release serves local only.", valueName: "selector"))
    public var source: SourceSelector = .local

    @Flag(name: .long, help: "Print the result as one JSON document.")
    public var json = false

    @Option(name: .long, help: ArgumentHelp("Give up after this many seconds.", valueName: "seconds"))
    public var timeout: Double?

    @Flag(name: .customLong("no-spawn"), help: "Fail instead of starting a CLI host when none is running.")
    public var noSpawn = false

    @Option(name: .customLong("host-directory"), help: ArgumentHelp("Directory holding the host's socket and records.", discussion: "Defaults to $\(CommandLineHostPaths.environmentVariable), then ~/Library/Application Support/\(CommandLineHostPaths.applicationDirectoryName)/CommandLineHost.", valueName: "path", visibility: .hidden))
    public var hostDirectory: String?

    public init() {}

    public var hostPaths: CommandLineHostPaths {
        CommandLineHostPaths.resolveDefault(override: hostDirectory)
    }
}

extension SourceSelector: ExpressibleByArgument {}
extension GenerationOptionsChoice: ExpressibleByArgument {}
extension TypeKindFilter: ExpressibleByArgument {}
extension ExportLayout: ExpressibleByArgument {}

extension GlobalOptions {
    /// Turns a path the user typed into the absolute path the host needs; the
    /// host's working directory has nothing to do with the client's.
    public static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
