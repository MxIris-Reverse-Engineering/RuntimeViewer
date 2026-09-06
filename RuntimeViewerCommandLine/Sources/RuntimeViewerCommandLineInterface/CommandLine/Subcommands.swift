import ArgumentParser
import Foundation

extension RuntimeViewerCommandLineTool {
    public struct Images: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List the images the host can inspect.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Flag(name: .long, help: "Only images that are loaded and indexed.")
        public var loaded = false

        @Option(name: .long, help: ArgumentHelp("Case-insensitive substring the path must contain.", valueName: "text"))
        public var query: String?

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .listImages(ListImagesCommand(source: globalOptions.source, loadedOnly: loaded, query: query))
            )
        }
    }

    public struct Load: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Load an image into the host and index it.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Argument(help: "Path of the Mach-O image, framework binary or dylib.")
        public var imagePath: String

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .loadImage(LoadImageCommand(source: globalOptions.source, imagePath: GlobalOptions.absolutePath(imagePath)))
            )
        }
    }

    public struct Types: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List the types of an image.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Option(name: .long, help: ArgumentHelp("Image path or short name. Defaults to every loaded image.", valueName: "image"))
        public var image: String?

        @Option(name: .long, help: ArgumentHelp("Only these kinds; repeatable.", valueName: "kind"))
        public var kind: [TypeKindFilter] = []

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .listTypes(ListTypesCommand(source: globalOptions.source, image: image.map(imageArgument), kinds: kind))
            )
        }
    }

    public struct Search: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Find types whose name contains text or matches a regular expression.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Argument(help: "Substring (case-insensitive) or, with --regex, a regular expression.")
        public var query: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name. Defaults to every loaded image.", valueName: "image"))
        public var image: String?

        @Flag(name: .long, help: "Treat the query as a regular expression.")
        public var regex = false

        @Option(name: .long, help: ArgumentHelp("Only these kinds; repeatable.", valueName: "kind"))
        public var kind: [TypeKindFilter] = []

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .searchTypes(SearchTypesCommand(source: globalOptions.source, image: image.map(imageArgument), query: query, isRegularExpression: regex, kinds: kind))
            )
        }
    }

    public struct Interface: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Print the interface of a type.")

        @OptionGroup public var globalOptions: GlobalOptions
        @OptionGroup public var generation: GenerationOptionsArguments

        @Argument(help: "Type name or display name.")
        public var typeName: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name. Defaults to every loaded image.", valueName: "image"))
        public var image: String?

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .interface(InterfaceCommand(source: globalOptions.source, image: image.map(imageArgument), typeName: typeName, options: generation.choice))
            )
        }
    }

    public struct Hierarchy: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Print the class hierarchy of a type.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Argument(help: "Type name or display name.")
        public var typeName: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name.", valueName: "image"))
        public var image: String?

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .hierarchy(HierarchyCommand(source: globalOptions.source, image: image.map(imageArgument), typeName: typeName))
            )
        }
    }

    public struct Relationships: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List the subclasses and conforming types of a type across the loaded images.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Argument(help: "Type name or display name.")
        public var typeName: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name.", valueName: "image"))
        public var image: String?

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .relationships(RelationshipsCommand(source: globalOptions.source, image: image.map(imageArgument), typeName: typeName))
            )
        }
    }

    public struct Members: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "List the runtime addresses of a type's members.")

        @OptionGroup public var globalOptions: GlobalOptions

        @Argument(help: "Type name or display name.")
        public var typeName: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name.", valueName: "image"))
        public var image: String?

        @Option(name: .long, help: ArgumentHelp("Only members whose name contains this text.", valueName: "text"))
        public var member: String?

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .memberAddresses(MemberAddressesCommand(source: globalOptions.source, image: image.map(imageArgument), typeName: typeName, memberName: member))
            )
        }
    }

    public struct Specialize: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Specialize a generic Swift type and print the resulting interface.",
            discussion: "Run with --list first to see the generic parameters and their candidates, then pass one --argument per parameter."
        )

        @OptionGroup public var globalOptions: GlobalOptions
        @OptionGroup public var generation: GenerationOptionsArguments

        @Argument(help: "Generic type name or display name.")
        public var typeName: String

        @Option(name: .long, help: ArgumentHelp("Image path or short name that defines the type.", valueName: "image"))
        public var image: String

        @Flag(name: .long, help: "List the generic parameters and candidates instead of specializing.")
        public var list = false

        @Option(name: .long, help: ArgumentHelp("Bind a generic parameter to a candidate; repeatable.", valueName: "Parameter=Type"))
        public var argument: [String] = []

        public init() {}

        public func validate() throws {
            for binding in argument where binding.split(separator: "=", maxSplits: 1).count != 2 {
                throw ValidationError("'\(binding)' is not of the form Parameter=Type.")
            }
        }

        public func run() async throws {
            var arguments: [String: String] = [:]
            for binding in argument {
                let parts = binding.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                arguments[parts[0]] = parts[1]
            }
            try await CommandRunner(globalOptions: globalOptions).run(
                .specialize(SpecializeCommand(source: globalOptions.source, image: imageArgument(image), typeName: typeName, arguments: arguments, listOnly: list, options: generation.choice))
            )
        }
    }

    public struct Export: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(abstract: "Export every interface of an image to a directory.")

        @OptionGroup public var globalOptions: GlobalOptions
        @OptionGroup public var generation: GenerationOptionsArguments

        @Argument(help: "Image path or short name.")
        public var image: String

        @Option(name: .long, help: ArgumentHelp("Directory to write into; created if missing.", valueName: "directory"))
        public var output: String

        @Option(name: .long, help: ArgumentHelp("Layout of the Objective-C headers.", valueName: "layout"))
        public var objc: ExportLayout = .single

        @Option(name: .long, help: ArgumentHelp("Layout of the Swift interfaces.", valueName: "layout"))
        public var swift: ExportLayout = .single

        @Flag(name: .customLong("no-metadata"), help: "Do not write the metadata file next to the interfaces.")
        public var noMetadata = false

        public init() {}

        public func run() async throws {
            try await CommandRunner(globalOptions: globalOptions).run(
                .export(ExportCommand(
                    source: globalOptions.source,
                    image: imageArgument(image),
                    outputDirectory: GlobalOptions.absolutePath(output),
                    objcLayout: objc,
                    swiftLayout: swift,
                    includeMetadata: !noMetadata,
                    options: generation.choice
                ))
            )
        }
    }
}

/// `--options` and its `--full` shorthand.
public struct GenerationOptionsArguments: ParsableArguments, Sendable {
    @Option(name: .long, help: ArgumentHelp("Interface generation options: default, full, or app (what the RuntimeViewer app has configured).", valueName: "choice"))
    public var options: GenerationOptionsChoice = .default

    @Flag(name: .long, help: "Shorthand for --options full.")
    public var full = false

    public init() {}

    public var choice: GenerationOptionsChoice {
        full ? .full : options
    }
}

/// An `--image` value: paths become absolute, short names pass through.
func imageArgument(_ value: String) -> String {
    if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") || value.contains("/") {
        return GlobalOptions.absolutePath(value)
    }
    return value
}
