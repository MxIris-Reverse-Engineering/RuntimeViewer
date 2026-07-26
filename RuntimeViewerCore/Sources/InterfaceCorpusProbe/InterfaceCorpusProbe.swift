import Darwin
import Foundation
import RuntimeViewerCore
import Semantic

/// Measurement probe for the global-search corpus design.
///
/// For every image path passed on the command line (defaulting to AppKit and
/// SwiftUI), the probe loads and indexes the image through a local
/// `RuntimeEngine`, prints the interface of every runtime object with maximal
/// generation options (`GenerationOptions.mcp` — all strip options off, all
/// comment/address/offset annotations on), and reports:
///
/// - plain-text corpus size (UTF-8 bytes) and line count
/// - comment share (bytes of `.comment`-typed components vs total)
/// - per-kind split (ObjC / Swift / C)
/// - child-object share (interfaces reachable only through `children`)
/// - indexing time, print time, and physical memory footprint checkpoints
///
/// The numbers feed the design decision recorded in the global-search plan:
/// whether an in-memory plain-text corpus over all indexed images is
/// affordable, and what including comments costs.
@main
struct InterfaceCorpusProbe {
    // MARK: - Measurement model

    struct ImageMeasurement {
        var imagePath: String
        var rootObjectCount = 0
        var childObjectCount = 0
        var printedInterfaceCount = 0
        var failedInterfaceCount = 0
        var emptyInterfaceCount = 0
        var totalUTF8ByteCount = 0
        var commentUTF8ByteCount = 0
        var newlineCount = 0
        /// Number of flattened `AtomicComponent`s across all printed interfaces.
        /// This is the `N` in the SemanticString per-token memory models
        /// (existential element ~40+48 B, cached flat component ~stride B).
        var tokenCount = 0
        /// Tokens carrying a non-nil span `identifier`.
        var identifierTokenCount = 0
        /// Tokens whose string exceeds the 15-byte inline small-string limit
        /// and therefore owns a heap allocation, plus their total UTF-8 bytes.
        var heapStringTokenCount = 0
        var heapStringUTF8ByteCount = 0
        /// Distinct span identifiers seen in this image's interfaces; sized to
        /// evaluate an interning table for the arena-storage design.
        var distinctIdentifiers: Set<String> = []
        var objectiveCUTF8ByteCount = 0
        var swiftUTF8ByteCount = 0
        var cUTF8ByteCount = 0
        var childObjectUTF8ByteCount = 0
        var loadSeconds: Double = 0
        var listSeconds: Double = 0
        var printSeconds: Double = 0
        var largestInterfaces: [(objectDisplayName: String, byteCount: Int)] = []

        mutating func recordLargestInterfaceCandidate(objectDisplayName: String, byteCount: Int) {
            largestInterfaces.append((objectDisplayName, byteCount))
            largestInterfaces.sort { $0.byteCount > $1.byteCount }
            if largestInterfaces.count > 5 {
                largestInterfaces.removeLast(largestInterfaces.count - 5)
            }
        }
    }

    // MARK: - Entry point

    static func main() async {
        let defaultImagePaths = [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI",
        ]
        let argumentImagePaths = Array(CommandLine.arguments.dropFirst())
        let imagePaths = argumentImagePaths.isEmpty ? defaultImagePaths : argumentImagePaths

        let generationOptions = RuntimeObjectInterface.GenerationOptions.mcp

        print("=== memory layout (arm64) ===")
        print("AtomicComponent:                size \(MemoryLayout<AtomicComponent>.size), stride \(MemoryLayout<AtomicComponent>.stride), alignment \(MemoryLayout<AtomicComponent>.alignment)")
        print("SemanticType:                   size \(MemoryLayout<SemanticType>.size), stride \(MemoryLayout<SemanticType>.stride)")
        print("any SemanticStringComponent:    size \(MemoryLayout<any SemanticStringComponent>.size), stride \(MemoryLayout<any SemanticStringComponent>.stride)")
        print("SemanticString:                 size \(MemoryLayout<SemanticString>.size), stride \(MemoryLayout<SemanticString>.stride)")

        let engine = RuntimeEngine(source: .local)
        do {
            try await engine.connect()
        } catch {
            logProgress("failed to connect local engine: \(error)")
            exit(1)
        }

        logProgress("physical footprint at start: \(formatByteCount(currentPhysicalFootprintByteCount()))")

        var measurements: [ImageMeasurement] = []
        for imagePath in imagePaths {
            if let measurement = await measureImage(
                engine: engine,
                imagePath: imagePath,
                generationOptions: generationOptions
            ) {
                measurements.append(measurement)
                printImageReport(measurement)
                logProgress("physical footprint after \(imagePath.split(separator: "/").last.map(String.init) ?? imagePath): \(formatByteCount(currentPhysicalFootprintByteCount()))")
            }
        }

        printCumulativeReport(measurements)

        var resourceUsage = rusage()
        if getrusage(RUSAGE_SELF, &resourceUsage) == 0 {
            // ru_maxrss is reported in bytes on Darwin.
            print("peak resident set size: \(formatByteCount(Int(resourceUsage.ru_maxrss)))")
        }
        print("physical footprint at exit: \(formatByteCount(currentPhysicalFootprintByteCount()))")
    }

    // MARK: - Per-image measurement

    private static func measureImage(
        engine: RuntimeEngine,
        imagePath: String,
        generationOptions: RuntimeObjectInterface.GenerationOptions
    ) async -> ImageMeasurement? {
        var measurement = ImageMeasurement(imagePath: imagePath)

        let loadStart = CFAbsoluteTimeGetCurrent()
        do {
            try await engine.loadImage(at: imagePath)
        } catch {
            logProgress("failed to load image \(imagePath): \(error)")
            return nil
        }
        measurement.loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart

        let listStart = CFAbsoluteTimeGetCurrent()
        let rootObjects: [RuntimeObject]
        do {
            rootObjects = try await engine.objects(in: imagePath)
        } catch {
            logProgress("failed to list objects in \(imagePath): \(error)")
            return nil
        }
        measurement.listSeconds = CFAbsoluteTimeGetCurrent() - listStart

        var flattenedObjects: [(object: RuntimeObject, depth: Int)] = []
        flatten(rootObjects, depth: 0, into: &flattenedObjects)
        measurement.rootObjectCount = rootObjects.count
        measurement.childObjectCount = flattenedObjects.count - rootObjects.count

        logProgress("\(imagePath): \(measurement.rootObjectCount) root objects, \(measurement.childObjectCount) child objects; printing …")

        let printStart = CFAbsoluteTimeGetCurrent()
        for (object, depth) in flattenedObjects {
            do {
                guard let interface = try await engine.interface(for: object, options: generationOptions) else {
                    measurement.emptyInterfaceCount += 1
                    continue
                }
                var interfaceByteCount = 0
                for component in interface.interfaceString.components {
                    let utf8View = component.string.utf8
                    let componentByteCount = utf8View.count
                    interfaceByteCount += componentByteCount
                    if component.type == .comment {
                        measurement.commentUTF8ByteCount += componentByteCount
                    }
                    for byte in utf8View where byte == 0x0A {
                        measurement.newlineCount += 1
                    }
                    measurement.tokenCount += 1
                    if let identifier = component.identifier {
                        measurement.identifierTokenCount += 1
                        measurement.distinctIdentifiers.insert(identifier)
                    }
                    if componentByteCount > 15 {
                        measurement.heapStringTokenCount += 1
                        measurement.heapStringUTF8ByteCount += componentByteCount
                    }
                }
                measurement.totalUTF8ByteCount += interfaceByteCount
                measurement.printedInterfaceCount += 1
                if depth > 0 {
                    measurement.childObjectUTF8ByteCount += interfaceByteCount
                }
                switch object.kind {
                case .objc:
                    measurement.objectiveCUTF8ByteCount += interfaceByteCount
                case .swift:
                    measurement.swiftUTF8ByteCount += interfaceByteCount
                case .c:
                    measurement.cUTF8ByteCount += interfaceByteCount
                }
                measurement.recordLargestInterfaceCandidate(
                    objectDisplayName: object.displayName,
                    byteCount: interfaceByteCount
                )
            } catch {
                measurement.failedInterfaceCount += 1
            }

            let processedCount = measurement.printedInterfaceCount
                + measurement.failedInterfaceCount
                + measurement.emptyInterfaceCount
            if processedCount % 500 == 0 {
                logProgress("  … \(processedCount)/\(flattenedObjects.count) interfaces, corpus \(formatByteCount(measurement.totalUTF8ByteCount)), footprint \(formatByteCount(currentPhysicalFootprintByteCount()))")
            }
        }
        measurement.printSeconds = CFAbsoluteTimeGetCurrent() - printStart
        return measurement
    }

    private static func flatten(
        _ objects: [RuntimeObject],
        depth: Int,
        into flattenedObjects: inout [(object: RuntimeObject, depth: Int)]
    ) {
        for object in objects {
            flattenedObjects.append((object, depth))
            flatten(object.children, depth: depth + 1, into: &flattenedObjects)
        }
    }

    // MARK: - Reporting

    private static func printImageReport(_ measurement: ImageMeasurement) {
        let codeOnlyByteCount = measurement.totalUTF8ByteCount - measurement.commentUTF8ByteCount
        let commentPercentage = percentage(measurement.commentUTF8ByteCount, of: measurement.totalUTF8ByteCount)
        let interfaceCount = max(measurement.printedInterfaceCount, 1)

        print("")
        print("=== \(measurement.imagePath) ===")
        print("objects:            \(measurement.rootObjectCount) roots + \(measurement.childObjectCount) children")
        print("interfaces:         \(measurement.printedInterfaceCount) printed, \(measurement.failedInterfaceCount) failed, \(measurement.emptyInterfaceCount) empty")
        print("load+index time:    \(formatSeconds(measurement.loadSeconds))")
        print("object list time:   \(formatSeconds(measurement.listSeconds))")
        print("print time:         \(formatSeconds(measurement.printSeconds)) (avg \(String(format: "%.2f", measurement.printSeconds * 1000 / Double(interfaceCount))) ms/interface)")
        print("corpus size:        \(formatByteCount(measurement.totalUTF8ByteCount)) UTF-8, \(measurement.newlineCount) lines")
        print("  comment bytes:    \(formatByteCount(measurement.commentUTF8ByteCount)) (\(commentPercentage))")
        print("  code-only bytes:  \(formatByteCount(codeOnlyByteCount))")
        print("  kind split:       objc \(formatByteCount(measurement.objectiveCUTF8ByteCount)), swift \(formatByteCount(measurement.swiftUTF8ByteCount)), c \(formatByteCount(measurement.cUTF8ByteCount))")
        print("  child-object part:\(formatByteCount(measurement.childObjectUTF8ByteCount)) (\(percentage(measurement.childObjectUTF8ByteCount, of: measurement.totalUTF8ByteCount)))")
        print("  avg per interface:\(formatByteCount(measurement.totalUTF8ByteCount / interfaceCount))")
        let tokenCount = max(measurement.tokenCount, 1)
        print("tokens:             \(measurement.tokenCount) (avg \(String(format: "%.1f", Double(measurement.totalUTF8ByteCount) / Double(tokenCount))) B/token)")
        print("  with identifier:  \(measurement.identifierTokenCount) (\(percentage(measurement.identifierTokenCount, of: measurement.tokenCount))), \(measurement.distinctIdentifiers.count) distinct")
        print("  heap strings:     \(measurement.heapStringTokenCount) (\(percentage(measurement.heapStringTokenCount, of: measurement.tokenCount))), \(formatByteCount(measurement.heapStringUTF8ByteCount))")
        print("  flat-array cost:  \(formatByteCount(measurement.tokenCount * MemoryLayout<AtomicComponent>.stride)) (tokens x stride)")
        print("  boxed-tree cost:  \(formatByteCount(measurement.tokenCount * (MemoryLayout<any SemanticStringComponent>.stride + 48))) (existential + malloc box, leaf lower bound)")
        print("largest interfaces:")
        for entry in measurement.largestInterfaces {
            print("  \(formatByteCount(entry.byteCount))  \(entry.objectDisplayName)")
        }
    }

    private static func printCumulativeReport(_ measurements: [ImageMeasurement]) {
        guard !measurements.isEmpty else { return }
        let totalByteCount = measurements.reduce(0) { $0 + $1.totalUTF8ByteCount }
        let totalCommentByteCount = measurements.reduce(0) { $0 + $1.commentUTF8ByteCount }
        let totalInterfaceCount = measurements.reduce(0) { $0 + $1.printedInterfaceCount }
        let totalFailedCount = measurements.reduce(0) { $0 + $1.failedInterfaceCount }
        let totalPrintSeconds = measurements.reduce(0) { $0 + $1.printSeconds }

        let totalTokenCount = measurements.reduce(0) { $0 + $1.tokenCount }
        let totalIdentifierTokenCount = measurements.reduce(0) { $0 + $1.identifierTokenCount }
        let totalHeapStringTokenCount = measurements.reduce(0) { $0 + $1.heapStringTokenCount }
        let totalHeapStringByteCount = measurements.reduce(0) { $0 + $1.heapStringUTF8ByteCount }
        let unionedDistinctIdentifiers = measurements.reduce(into: Set<String>()) { $0.formUnion($1.distinctIdentifiers) }

        print("")
        print("=== cumulative (\(measurements.count) images) ===")
        print("interfaces:         \(totalInterfaceCount) printed, \(totalFailedCount) failed")
        print("corpus size:        \(formatByteCount(totalByteCount))")
        print("  comment bytes:    \(formatByteCount(totalCommentByteCount)) (\(percentage(totalCommentByteCount, of: totalByteCount)))")
        print("  code-only bytes:  \(formatByteCount(totalByteCount - totalCommentByteCount))")
        print("tokens:             \(totalTokenCount)")
        print("  with identifier:  \(totalIdentifierTokenCount) (\(percentage(totalIdentifierTokenCount, of: totalTokenCount))), \(unionedDistinctIdentifiers.count) distinct")
        print("  heap strings:     \(totalHeapStringTokenCount) (\(percentage(totalHeapStringTokenCount, of: totalTokenCount))), \(formatByteCount(totalHeapStringByteCount))")
        print("  flat-array cost:  \(formatByteCount(totalTokenCount * MemoryLayout<AtomicComponent>.stride))")
        print("  boxed-tree cost:  \(formatByteCount(totalTokenCount * (MemoryLayout<any SemanticStringComponent>.stride + 48)))")
        print("print time:         \(formatSeconds(totalPrintSeconds))")
    }

    // MARK: - Formatting helpers

    private static func percentage(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.1f%%", Double(part) * 100 / Double(whole))
    }

    private static func formatByteCount(_ byteCount: Int) -> String {
        if byteCount >= 1_000_000_000 {
            return String(format: "%.2f GB", Double(byteCount) / 1_000_000_000)
        } else if byteCount >= 1_000_000 {
            return String(format: "%.1f MB", Double(byteCount) / 1_000_000)
        } else if byteCount >= 1_000 {
            return String(format: "%.1f KB", Double(byteCount) / 1_000)
        } else {
            return "\(byteCount) B"
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }

    // MARK: - Process introspection helpers

    private static func currentPhysicalFootprintByteCount() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }

    private static func logProgress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
