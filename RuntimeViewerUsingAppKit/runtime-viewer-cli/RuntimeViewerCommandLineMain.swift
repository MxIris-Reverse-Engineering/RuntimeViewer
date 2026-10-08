// `main()` comes from ArgumentParser, and this target enables
// `MemberImportVisibility`: a member is only visible when its defining module is
// imported directly, so the transitive import through the interface library is
// not enough.
import ArgumentParser
import RuntimeViewerCommandLineInterface
import RuntimeViewerInjection

/// The copy embedded in the app bundle. Everything else lives in the library,
/// so this entry point and the package's own are the same three lines.
///
/// An `@main` type rather than `main.swift`: at top level, `await Tool.main()`
/// resolves to the synchronous `ParsableCommand.main()` and the async
/// subcommands never run. The file name matters too — a file called `main.swift`
/// is top-level code, which `@main` cannot coexist with.
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
