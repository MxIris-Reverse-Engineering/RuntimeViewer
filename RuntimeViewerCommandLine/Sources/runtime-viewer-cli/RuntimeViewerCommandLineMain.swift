import RuntimeViewerCommandLineInterface
import RuntimeViewerInjection

/// The whole executable: everything else lives in the library so a second
/// entry point (the copy embedded in the app bundle) is the same three lines.
///
/// An `@main` type rather than `main.swift`: at top level, `await Tool.main()`
/// resolves to the synchronous `ParsableCommand.main()` and the async
/// subcommands never run.
@main
enum RuntimeViewerCommandLineMain {
    static func main() async {
        // The resident host serves engines of its own, so it registers the
        // injection commands like every other process that does. It has no
        // `RuntimeInjectionService`: injecting on this Mac goes through the
        // privileged helper daemon, and a capability query answered honestly
        // is what tells a host that.
        RuntimeInjection.install()
        await RuntimeViewerCommandLineTool.main()
    }
}
