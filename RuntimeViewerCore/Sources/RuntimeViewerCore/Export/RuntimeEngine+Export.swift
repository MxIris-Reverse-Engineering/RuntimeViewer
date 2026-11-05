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
        let allObjects = try await objects(in: configuration.imagePath)
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        let total = allObjects.count

        for (index, object) in allObjects.enumerated() {
            try Task.checkCancellation()
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                guard let runtimeInterface = try await interface(for: object, options: configuration.generationOptions) else {
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
                if item.isSwift { swiftCount += 1 } else { objcCount += 1 }
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
            let objcItems = results.filter { !$0.isSwift }
            let swiftItems = results.filter { $0.isSwift }

            if !objcItems.isEmpty {
                switch configuration.objcFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: objcItems,
                        to: configuration.directory,
                        imageName: configuration.imageName,
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: objcItems,
                        to: configuration.directory,
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
            }

            if !swiftItems.isEmpty {
                switch configuration.swiftFormat {
                case .singleFile:
                    try RuntimeInterfaceExportWriter.writeSingleFile(
                        items: swiftItems,
                        to: configuration.directory,
                        imageName: configuration.imageName,
                    )
                case .directory:
                    let writeResult = try RuntimeInterfaceExportWriter.writeDirectory(
                        items: swiftItems,
                        to: configuration.directory,
                    )
                    for (failedItem, writeError) in writeResult.failedItems {
                        reporter.send(.objectFailed(failedItem.object, writeError))
                    }
                    writeFailed += writeResult.failedItems.count
                }
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
        )
        reporter.send(.completed(result))
    }
}
