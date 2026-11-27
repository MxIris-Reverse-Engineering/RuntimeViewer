import MachOKit
import FoundationToolbox
import RuntimeViewerObjC
import Foundation
import Combine
import RuntimeViewerCommunication
import Demangling
import OrderedCollections

extension RuntimeEngine {
    public enum RuntimeExportError: Error {
        case interfaceGenerationFailed(RuntimeObject)
    }

    public func exportInterfaces(
        with configuration: RuntimeInterfaceExportConfiguration,
        reporter: RuntimeInterfaceExportReporter,
    ) async throws {
        defer { reporter.finish() }
        let startTime = CFAbsoluteTimeGetCurrent()

        reporter.send(.phaseStarted(.preparing))
        // A C++ interface names the classes and namespaces declared in it
        // without printing them, so each of them is exported on its own.
        let allObjects = try await objects(
            in: configuration.imagePath,
            includesCPlusPlusObjects: configuration.includesCPlusPlusObjects
        ).exportedObjects
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        var cPlusPlusCount = 0
        let total = allObjects.count
        // An export keeps its text: it waits for the serving process's type
        // index rather than writing the `__C.` names it would print while the
        // index is still being built (proposal swift-type-indexing-package).
        var exportGenerationOptions = configuration.generationOptions
        exportGenerationOptions.waitsForTypeIndex = true

        for (index, object) in allObjects.enumerated() {
            try Task.checkCancellation()
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                guard let runtimeInterface = try await interface(for: object, options: exportGenerationOptions) else {
                    throw RuntimeExportError.interfaceGenerationFailed(object)
                }
                // Printed as empty: everything in it is left out by Print
                // Exported Declarations Only. Exported as nothing rather than
                // as an empty file, and counted neither way.
                guard !runtimeInterface.interfaceString.isEmpty else {
                    reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
                    continue
                }
                let item = RuntimeInterfaceExportItem(
                    object: object,
                    plainText: runtimeInterface.interfaceString.string,
                    suggestedFileName: object.exportFileName,
                )
                results.append(item)
                succeeded += 1
                switch item.group {
                case .objectiveC: objcCount += 1
                case .swift: swiftCount += 1
                case .cPlusPlus: cPlusPlusCount += 1
                }
                reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
            } catch {
                failed += 1
                reporter.send(.objectFailed(object, error))
            }
        }
        reporter.send(.phaseCompleted(.exporting))

        reporter.send(.phaseStarted(.writing))

        var writeFailed = 0

        do {
            for group in RuntimeInterfaceExportItem.Group.allCases {
                let items = results.filter { $0.group == group }
                guard !items.isEmpty else { continue }
                let writeResult = try RuntimeInterfaceExportWriter.write(
                    items,
                    as: group,
                    format: configuration.format(for: group),
                    to: configuration.directory,
                    imageName: configuration.imageName,
                )
                for (failedItem, writeError) in writeResult.failedItems {
                    reporter.send(.objectFailed(failedItem.object, writeError))
                }
                writeFailed += writeResult.failedItems.count
            }

            if configuration.includeMetadata {
                let module = try await dispatch(
                    ExportModuleInfoCommand(
                        imagePath: configuration.imagePath,
                        imageName: configuration.imageName
                    )
                )
                let metadata = RuntimeInterfaceExportMetadata.make(
                    configuration: configuration,
                    module: module,
                    objcInterfaceCount: objcCount,
                    swiftInterfaceCount: swiftCount,
                    cPlusPlusInterfaceCount: cPlusPlusCount,
                    succeeded: succeeded,
                    failed: failed + writeFailed,
                )
                try RuntimeInterfaceExportWriter.writeMetadata(metadata, to: configuration.directory)
            }

            reporter.send(.phaseCompleted(.writing))
        } catch {
            reporter.send(.phaseFailed(.writing, error))
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let result = RuntimeInterfaceExportResult(
            succeeded: succeeded,
            failed: failed + writeFailed,
            totalDuration: duration,
            objcCount: objcCount,
            swiftCount: swiftCount,
            cPlusPlusCount: cPlusPlusCount,
        )
        reporter.send(.completed(result))
    }
}
