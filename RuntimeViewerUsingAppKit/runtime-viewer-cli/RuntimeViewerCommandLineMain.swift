// `main()` comes from ArgumentParser, and this target enables
// `MemberImportVisibility`: a member is only visible when its defining module is
// imported directly, so the transitive import through the interface library is
// not enough.
import ArgumentParser
import RuntimeViewerCommandLineInterface

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
        await RuntimeViewerCommandLineTool.main()
    }
}
