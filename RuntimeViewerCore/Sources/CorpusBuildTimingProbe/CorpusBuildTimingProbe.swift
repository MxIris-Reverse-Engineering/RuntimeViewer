import Darwin
import Foundation
import RuntimeViewerCore

/// Times the Find corpus build and the content pane's printing, per image and
/// per Generation Options preset — the numbers `draft-find-navigator` §1.1
/// asks for before and after each speed-up. Branch-only: this target is
/// never merged.
///
/// ```
/// CorpusBuildTimingProbe corpus [image …]
/// CorpusBuildTimingProbe display <preset> [--top-level-only] [image …]
/// CorpusBuildTimingProbe presets
/// ```
///
/// - `corpus` builds each image's corpus through the engine, the request the
///   Find navigator sends: every object printed once in marking mode, frozen,
///   split into text and visibility regions, its members located.
/// - `display` prints every object of each image the way the content pane
///   asks for it, under one preset. Two presets' print times subtracted give
///   what the options between them cost. Nested objects are timed apart,
///   because the corpus prints them a second time on their own;
///   `--top-level-only` leaves them out altogether.
///
/// Images are paths, or one of `Foundation`, `SwiftUI`, `SwiftUICore`,
/// `AppKit`, `libswiftCore`; the default is Foundation, SwiftUI and
/// libswiftCore. Run one mode and one preset per process: printing warms
/// process-wide caches a second run in the same process would inherit.
@main
struct CorpusBuildTimingProbe {
    // MARK: - Arguments

    private enum Mode {
        case corpus
        case display(presetName: String, options: RuntimeObjectInterface.GenerationOptions, isTopLevelOnly: Bool)
    }

    private static let defaultImageNames = ["Foundation", "SwiftUI", "libswiftCore"]

    private static let imagePathsByShortName: [String: String] = [
        "Foundation": "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
        "SwiftUI": "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI",
        "SwiftUICore": "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore",
        "AppKit": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "libswiftCore": "/usr/lib/swift/libswiftCore.dylib",
    ]

    /// `mcp` is what the corpus marks (everything shown); each `mcp-no-…`
    /// turns one option back off, so its difference from `mcp` is that
    /// option's cost. `mcp-no-field-offset` also turns off the expansion,
    /// which has nothing to expand without it.
    private static let presets: [(name: String, options: RuntimeObjectInterface.GenerationOptions)] = {
        func mcp(changing change: (inout RuntimeObjectInterface.GenerationOptions) -> Void) -> RuntimeObjectInterface.GenerationOptions {
            var options = RuntimeObjectInterface.GenerationOptions.mcp
            change(&options)
            return options
        }
        return [
            ("default", RuntimeObjectInterface.GenerationOptions(objcHeaderOptions: .default, swiftInterfaceOptions: .default, transformer: .default)),
            ("mcp", .mcp),
            ("mcp-no-expanded-field-offset", mcp { $0.swiftInterfaceOptions.printExpandedFieldOffset = false }),
            ("mcp-no-field-offset", mcp {
                $0.swiftInterfaceOptions.printFieldOffset = false
                $0.swiftInterfaceOptions.printExpandedFieldOffset = false
            }),
            ("mcp-no-type-layout", mcp { $0.swiftInterfaceOptions.printTypeLayout = false }),
            ("mcp-no-enum-layout", mcp { $0.swiftInterfaceOptions.printEnumLayout = false }),
            ("mcp-no-member-address", mcp { $0.swiftInterfaceOptions.printMemberAddress = false }),
            ("mcp-no-vtable-offset", mcp { $0.swiftInterfaceOptions.printVTableOffset = false }),
            ("mcp-no-pwt-offset", mcp { $0.swiftInterfaceOptions.printPWTOffset = false }),
            ("mcp-no-stripped-symbolic-item", mcp { $0.swiftInterfaceOptions.printStrippedSymbolicItem = false }),
            ("mcp-no-opaque-type", mcp { $0.swiftInterfaceOptions.synthesizeOpaqueType = false }),
            ("mcp-no-objc-comments", mcp {
                $0.objcHeaderOptions.addIvarOffsetComments = false
                $0.objcHeaderOptions.addPropertyAttributesComments = false
                $0.objcHeaderOptions.addMethodIMPAddressComments = false
                $0.objcHeaderOptions.addPropertyAccessorAddressComments = false
            }),
        ]
    }()

    // MARK: - Entry point

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let modeName = arguments.first else {
            printUsageAndExit()
        }
        arguments.removeFirst()

        let mode: Mode
        switch modeName {
        case "presets":
            for preset in presets {
                print(preset.name)
            }
            return
        case "corpus":
            mode = .corpus
        case "display":
            guard let presetName = arguments.first else { printUsageAndExit() }
            arguments.removeFirst()
            guard let preset = presets.first(where: { $0.name == presetName }) else {
                logProgress("unknown preset \(presetName); run `presets` for the list")
                exit(2)
            }
            let isTopLevelOnly = arguments.contains("--top-level-only")
            arguments.removeAll { $0 == "--top-level-only" }
            mode = .display(presetName: preset.name, options: preset.options, isTopLevelOnly: isTopLevelOnly)
        default:
            printUsageAndExit()
        }

        let imageNames = arguments.isEmpty ? defaultImageNames : arguments
        let imagePaths = imageNames.map { imagePathsByShortName[$0] ?? $0 }

        let engine = RuntimeEngine(source: .local)
        do {
            try await engine.connect()
        } catch {
            logProgress("failed to connect the local engine: \(error)")
            exit(1)
        }

        print("machine: \(hostName()), \(ProcessInfo.processInfo.activeProcessorCount) active cores")
        for imagePath in imagePaths {
            await measure(imagePath: imagePath, mode: mode, engine: engine)
        }
        var resourceUsage = rusage()
        getrusage(RUSAGE_SELF, &resourceUsage)
        // `ru_maxrss` is in bytes on Darwin.
        print("peak resident set size: \(formatByteCount(Int(resourceUsage.ru_maxrss)))")
    }

    private static func printUsageAndExit() -> Never {
        logProgress("""
        usage: CorpusBuildTimingProbe corpus [image …]
               CorpusBuildTimingProbe display <preset> [--top-level-only] [image …]
               CorpusBuildTimingProbe presets
        images: a path, or \(imagePathsByShortName.keys.sorted().joined(separator: ", ")); default \(defaultImageNames.joined(separator: ", "))
        """)
        exit(2)
    }

    // MARK: - Measuring

    private static func measure(imagePath: String, mode: Mode, engine: RuntimeEngine) async {
        let imageName = (imagePath as NSString).lastPathComponent
        let loadStart = Measurement.start()
        do {
            try await engine.loadImage(at: imagePath)
        } catch {
            logProgress("\(imageName): failed to load: \(error)")
            return
        }
        let load = loadStart.finish()

        let listStart = Measurement.start()
        let rootObjects: [RuntimeObject]
        do {
            rootObjects = try await engine.objects(in: imagePath)
        } catch {
            logProgress("\(imageName): failed to list objects: \(error)")
            return
        }
        let list = listStart.finish()

        var flattenedObjects: [(object: RuntimeObject, depth: Int)] = []
        flatten(rootObjects, depth: 0, into: &flattenedObjects)
        let nestedObjectCount = flattenedObjects.count - rootObjects.count

        print("")
        print("=== \(imageName) ===")
        print("objects:      \(rootObjects.count) top-level + \(nestedObjectCount) nested")
        print("load+index:   \(load)")
        print("list:         \(list)")

        switch mode {
        case .corpus:
            await measureCorpus(imageName: imageName, imagePath: imagePath, engine: engine)
        case .display(let presetName, let options, let isTopLevelOnly):
            let objects = isTopLevelOnly ? flattenedObjects.filter { $0.depth == 0 } : flattenedObjects
            await measureDisplay(imageName: imageName, presetName: presetName, options: options, isTopLevelOnly: isTopLevelOnly, objects: objects, engine: engine)
        }
    }

    private static func measureCorpus(imageName: String, imagePath: String, engine: RuntimeEngine) async {
        let buildStart = Measurement.start()
        let progressReporter = ProgressReporter(imageName: imageName)
        let summary: RuntimeInterfaceCorpusBuildSummary
        do {
            summary = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default) { progress in
                progressReporter.report(built: progress.built, total: progress.total)
            }
        } catch {
            logProgress("\(imageName): corpus build failed: \(error)")
            return
        }
        let build = buildStart.finish()
        print("mode:         corpus")
        print("corpus build: \(build)")
        print("entries:      \(summary.objectCount) built, \(summary.skippedCount) skipped, \(formatByteCount(summary.byteCount))")
        print("per object:   \(formatMilliseconds(build.wallSeconds / Double(max(summary.objectCount + summary.skippedCount, 1))))")
    }

    private static func measureDisplay(
        imageName: String,
        presetName: String,
        options: RuntimeObjectInterface.GenerationOptions,
        isTopLevelOnly: Bool,
        objects: [(object: RuntimeObject, depth: Int)],
        engine: RuntimeEngine
    ) async {
        var secondsByKind: [String: Double] = [:]
        var countByKind: [String: Int] = [:]
        var nestedSeconds: Double = 0
        var printedCount = 0
        var emptyCount = 0
        var failedCount = 0
        var byteCount = 0
        var slowestObjects: [(name: String, seconds: Double)] = []
        let progressReporter = ProgressReporter(imageName: imageName)

        let printStart = Measurement.start()
        for (index, entry) in objects.enumerated() {
            let objectStart = monotonicSeconds()
            do {
                if let interface = try await engine.interface(for: entry.object, options: options) {
                    printedCount += 1
                    byteCount += interface.interfaceString.text.utf8.count
                } else {
                    emptyCount += 1
                }
            } catch {
                failedCount += 1
            }
            let seconds = monotonicSeconds() - objectStart
            let kindName = kindName(of: entry.object)
            secondsByKind[kindName, default: 0] += seconds
            countByKind[kindName, default: 0] += 1
            if entry.depth > 0 {
                nestedSeconds += seconds
            }
            recordSlowObject(name: entry.object.displayName, seconds: seconds, in: &slowestObjects)
            progressReporter.report(built: index + 1, total: objects.count)
        }
        let printing = printStart.finish()

        print("mode:         display \(presetName)\(isTopLevelOnly ? " --top-level-only" : "")")
        print("print:        \(printing)")
        print("interfaces:   \(printedCount) printed, \(emptyCount) empty, \(failedCount) failed, \(formatByteCount(byteCount))")
        for kindName in secondsByKind.keys.sorted() {
            let seconds = secondsByKind[kindName] ?? 0
            print("  \(kindName.padding(toLength: 6, withPad: " ", startingAt: 0))      \(formatSeconds(seconds)) over \(countByKind[kindName] ?? 0) objects (\(formatPercentage(seconds, of: printing.wallSeconds)))")
        }
        if !isTopLevelOnly {
            print("  nested      \(formatSeconds(nestedSeconds)) (\(formatPercentage(nestedSeconds, of: printing.wallSeconds)))")
        }
        print("slowest:")
        for slowObject in slowestObjects {
            print("  \(formatSeconds(slowObject.seconds))  \(slowObject.name)")
        }
    }

    private static func flatten(_ objects: [RuntimeObject], depth: Int, into flattenedObjects: inout [(object: RuntimeObject, depth: Int)]) {
        for object in objects {
            flattenedObjects.append((object, depth))
            flatten(object.children, depth: depth + 1, into: &flattenedObjects)
        }
    }

    private static func kindName(of object: RuntimeObject) -> String {
        switch object.kind {
        case .objc: "objc"
        case .swift: "swift"
        case .c: "c"
        }
    }

    private static func recordSlowObject(name: String, seconds: Double, in slowestObjects: inout [(name: String, seconds: Double)]) {
        guard slowestObjects.count < 5 || seconds > slowestObjects[slowestObjects.count - 1].seconds else { return }
        slowestObjects.append((name, seconds))
        slowestObjects.sort { $0.seconds > $1.seconds }
        if slowestObjects.count > 5 {
            slowestObjects.removeLast()
        }
    }

    // MARK: - Clock and processor time

    /// Wall time and the processor time the whole process spent meanwhile —
    /// their ratio is how many cores the step kept busy.
    private struct Measurement: CustomStringConvertible {
        let wallSeconds: Double
        let processorSeconds: Double

        struct Start {
            let wallStart: Double
            let processorStart: Double

            func finish() -> Measurement {
                Measurement(
                    wallSeconds: CorpusBuildTimingProbe.monotonicSeconds() - wallStart,
                    processorSeconds: CorpusBuildTimingProbe.processorSeconds() - processorStart
                )
            }
        }

        static func start() -> Start {
            Start(wallStart: CorpusBuildTimingProbe.monotonicSeconds(), processorStart: CorpusBuildTimingProbe.processorSeconds())
        }

        var description: String {
            let busyCores = wallSeconds > 0 ? processorSeconds / wallSeconds : 0
            return "\(formatSeconds(wallSeconds)) wall, \(formatSeconds(processorSeconds)) processor (\(String(format: "%.2f", busyCores)) cores busy)"
        }
    }

    /// The package still deploys to macOS 10.15, before `ContinuousClock`.
    fileprivate static func monotonicSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    fileprivate static func processorSeconds() -> Double {
        var resourceUsage = rusage()
        getrusage(RUSAGE_SELF, &resourceUsage)
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(resourceUsage.ru_utime) + seconds(resourceUsage.ru_stime)
    }

    /// Progress to standard error every ten percent, so standard output holds
    /// only the report.
    private final class ProgressReporter: @unchecked Sendable {
        private let imageName: String
        private let lock = NSLock()
        private var lastReportedTenth = 0

        init(imageName: String) {
            self.imageName = imageName
        }

        func report(built: Int, total: Int) {
            guard total > 0 else { return }
            let tenth = built * 10 / total
            lock.lock()
            defer { lock.unlock() }
            guard tenth > lastReportedTenth else { return }
            lastReportedTenth = tenth
            CorpusBuildTimingProbe.logProgress("\(imageName): \(built)/\(total)")
        }
    }

    // MARK: - Formatting

    fileprivate static func logProgress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        return String(cString: buffer)
    }

    fileprivate static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f s", seconds)
    }

    private static func formatMilliseconds(_ seconds: Double) -> String {
        String(format: "%.2f ms", seconds * 1000)
    }

    private static func formatPercentage(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.1f%%", part * 100 / whole)
    }

    private static func formatByteCount(_ byteCount: Int) -> String {
        if byteCount >= 1_000_000_000 {
            return String(format: "%.2f GB", Double(byteCount) / 1_000_000_000)
        } else if byteCount >= 1_000_000 {
            return String(format: "%.1f MB", Double(byteCount) / 1_000_000)
        } else if byteCount >= 1_000 {
            return String(format: "%.1f KB", Double(byteCount) / 1_000)
        }
        return "\(byteCount) B"
    }
}
