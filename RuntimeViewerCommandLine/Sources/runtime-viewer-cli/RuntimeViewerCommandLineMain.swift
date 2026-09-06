import RuntimeViewerCommandLineInterface

/// The whole executable: everything else lives in the library so a second
/// entry point (the copy embedded in the app bundle) is the same three lines.
///
/// An `@main` type rather than `main.swift`: at top level, `await Tool.main()`
/// resolves to the synchronous `ParsableCommand.main()` and the async
/// subcommands never run.
@main
enum RuntimeViewerCommandLineMain {
    static func main() async {
        await RuntimeViewerCommandLineTool.main()
    }
}
