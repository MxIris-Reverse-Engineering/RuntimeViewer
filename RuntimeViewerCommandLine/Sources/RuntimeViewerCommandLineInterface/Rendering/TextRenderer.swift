import Foundation

/// What a renderer produces: the document for standard output, plus notes
/// that belong on standard error so they never mix with the result.
public struct RenderedOutput: Equatable, Sendable {
    public var output: String
    public var notes: [String]

    public init(output: String, notes: [String] = []) {
        self.output = output
        self.notes = notes
    }
}

/// Human-readable rendering of results and failures.
public enum TextRenderer {
    public static func render(_ result: CommandResult) -> RenderedOutput {
        switch result {
        case .imageList(let result):
            return render(result)
        case .imageLoaded(let result):
            let state = result.wasAlreadyLoaded ? "Indexed" : "Loaded and indexed"
            return RenderedOutput(output: "\(state) \(result.imagePath): \(result.objectCount) type\(result.objectCount == 1 ? "" : "s")\n")
        case .typeList(let result):
            return render(result)
        case .interface(let result):
            return RenderedOutput(output: terminated(result.interfaceText))
        case .hierarchy(let result):
            return render(result)
        case .relationships(let result):
            return render(result)
        case .memberAddresses(let result):
            return render(result)
        case .specializationParameters(let result):
            return render(result)
        case .specialized(let result):
            return RenderedOutput(output: terminated(result.interfaceText), notes: result.warnings.map { "warning: \($0)" })
        case .export(let result):
            return render(result)
        case .hostStatus(let result):
            return render(result)
        case .shutdownAcknowledged(let result):
            return RenderedOutput(output: "CLI host \(result.processIdentifier) is shutting down (\(result.reason.rawValue)).\n")
        }
    }

    public static func render(_ failure: CommandFailure) -> String {
        "error: \(failure.message) [\(failure.code.rawValue)]\n"
    }

    // MARK: - Per result

    private static func render(_ result: ImageListResult) -> RenderedOutput {
        guard !result.images.isEmpty else {
            return RenderedOutput(output: "No images.\n")
        }
        let table = TextTable(
            header: ["LOADED", "NAME", "PATH"],
            rows: result.images.map { [$0.isLoaded ? "*" : "", $0.name, $0.path] }
        )
        return RenderedOutput(output: table.render())
    }

    private static func render(_ result: TypeListResult) -> RenderedOutput {
        guard !result.types.isEmpty else {
            return RenderedOutput(output: "No types matched in \(scopeDescription(result.imagePaths)).\n")
        }
        let table = TextTable(
            header: ["KIND", "NAME", "IMAGE"],
            rows: result.types.map { [$0.kind, $0.displayName, $0.imageName] }
        )
        return RenderedOutput(output: table.render())
    }

    private static func render(_ result: HierarchyResult) -> RenderedOutput {
        guard !result.hierarchy.isEmpty else {
            return RenderedOutput(output: "\(result.typeInfo.displayName) has no class hierarchy.\n")
        }
        var lines: [String] = []
        for (depth, name) in result.hierarchy.enumerated() {
            lines.append(String(repeating: "  ", count: depth) + name)
        }
        return RenderedOutput(output: lines.joined(separator: "\n") + "\n")
    }

    private static func render(_ result: RelationshipsResult) -> RenderedOutput {
        var lines: [String] = []
        lines.append("Subclasses (\(result.subclasses.count)):")
        lines.append(contentsOf: result.subclasses.map { "  \($0.displayName) (\($0.imageName))" })
        lines.append("Conforming types (\(result.conformingTypes.count)):")
        lines.append(contentsOf: result.conformingTypes.map { "  \($0.displayName) (\($0.imageName))" })
        return RenderedOutput(output: lines.joined(separator: "\n") + "\n")
    }

    private static func render(_ result: MemberAddressesResult) -> RenderedOutput {
        guard !result.members.isEmpty else {
            return RenderedOutput(output: "No member addresses for \(result.typeInfo.displayName).\n")
        }
        let table = TextTable(
            header: ["ADDRESS", "KIND", "NAME", "SYMBOL"],
            rows: result.members.map { [$0.address, $0.kind, $0.name, $0.symbolName] }
        )
        return RenderedOutput(output: table.render())
    }

    private static func render(_ result: SpecializationParametersResult) -> RenderedOutput {
        var lines = ["Generic parameters of \(result.typeInfo.displayName):"]
        for parameter in result.parameters {
            lines.append("  \(parameter.name): \(parameter.displayDescription)")
            if parameter.candidates.isEmpty {
                lines.append("    (no candidates)")
            }
            for candidate in parameter.candidates {
                let generic = candidate.isGeneric ? ", generic" : ""
                lines.append("    - \(candidate.displayName) (\(candidate.kind), \(candidate.imageName)\(generic))")
            }
        }
        return RenderedOutput(output: lines.joined(separator: "\n") + "\n")
    }

    private static func render(_ result: ExportResult) -> RenderedOutput {
        let duration = String(format: "%.1f", result.totalDuration)
        let failed = result.failed == 0 ? "" : ", \(result.failed) failed"
        return RenderedOutput(output: "Exported \(result.succeeded) interface\(result.succeeded == 1 ? "" : "s") of \(result.imageName) to \(result.outputDirectory) in \(duration) s (Objective-C \(result.objcCount), Swift \(result.swiftCount)\(failed)).\n")
    }

    private static func render(_ result: HostStatusResult) -> RenderedOutput {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "Kind:               \(result.kind.rawValue)",
            "Process:            \(result.processIdentifier)",
            "Version:            \(result.version) (protocol \(result.protocolVersion))",
            "Started:            \(formatter.string(from: result.startedAt))",
            "Connections:        \(result.activeConnections)",
            "Commands in flight: \(result.inFlightCommands)",
            "Idle timeout:       \(result.idleTimeout.map { "\(Int($0)) s" } ?? "never")",
            "Shutting down:      \(result.isShuttingDown ? "yes" : "no")",
            "Loaded images:      \(result.loadedImagePaths.count)",
        ]
        lines.append(contentsOf: result.loadedImagePaths.map { "  \($0)" })
        return RenderedOutput(output: lines.joined(separator: "\n") + "\n")
    }

    // MARK: - Helpers

    private static func scopeDescription(_ imagePaths: [String]) -> String {
        switch imagePaths.count {
        case 0: return "no image"
        case 1: return imagePaths[0]
        default: return "\(imagePaths.count) images"
        }
    }

    private static func terminated(_ text: String) -> String {
        text.hasSuffix("\n") ? text : text + "\n"
    }
}

/// Left-aligned columns separated by two spaces, no trailing whitespace.
struct TextTable {
    var header: [String]
    var rows: [[String]]

    func render() -> String {
        let allRows = [header] + rows
        let columnCount = header.count
        var widths = Array(repeating: 0, count: columnCount)
        for row in allRows {
            for (index, cell) in row.prefix(columnCount).enumerated() {
                widths[index] = max(widths[index], cell.count)
            }
        }
        var lines: [String] = []
        for row in allRows {
            var line = ""
            for (index, cell) in row.prefix(columnCount).enumerated() {
                let isLast = index == columnCount - 1
                line += isLast ? cell : cell.padding(toLength: widths[index] + 2, withPad: " ", startingAt: 0)
            }
            lines.append(line.trimmingTrailingSpaces())
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var result = self
        while result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }
}
