import ArgumentParser
import Foundation

/// The `runtime-viewer-cli` entry point. Lives in the library so the
/// executable target is one line and a second entry point can reuse it.
public struct RuntimeViewerCommandLineTool: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "runtime-viewer-cli",
        abstract: "Inspect Objective-C and Swift runtime interfaces without opening RuntimeViewer.",
        discussion: """
            While the RuntimeViewer app runs, it answers these commands and every source it has \
            (attached processes, devices on the network) is available. Otherwise the first command \
            starts a background CLI host that keeps the runtime engines and their indexes warm; it \
            exits on its own after \(Int(HostIdleTimeout.defaultSeconds)) s without connections or \
            commands. Pass --json to any command for machine-readable output.
            """,
        version: CommandLineToolVersion.current,
        subcommands: [
            Images.self,
            Load.self,
            Types.self,
            Search.self,
            Interface.self,
            Hierarchy.self,
            Relationships.self,
            Members.self,
            Specialize.self,
            Export.self,
            Sources.self,
            Attach.self,
            Detach.self,
            Host.self,
        ]
    )

    public init() {}
}
