#if os(macOS)

import Foundation
import FoundationToolbox
import HelperCommunication
import HelperService
import RuntimeViewerCommunication

/// Handles `FileOperationRequest` by routing each operation to `FileManager.default`.
/// Runs with daemon privileges so callers can perform file operations under paths
/// the host app can't touch directly (e.g. `/Library/Frameworks/...`).
@Loggable
public actor FilesService: HelperService {
    public enum Error: Swift.Error {
        case deallocated
    }

    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: FileOperationRequest) -> FileOperationRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.perform(request: request)
        }
    }

    public func run() async throws {}

    private func perform(request: FileOperationRequest) async throws -> FileOperationRequest.Response {
        let fileManager = FileManager.default
        switch request.operation {
        case let .createDirectory(url, isIntermediateDirectories):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: isIntermediateDirectories)
        case let .remove(url: url):
            try fileManager.removeItem(at: url)
        case let .move(from: from, to: to):
            try fileManager.moveItem(at: from, to: to)
        case let .copy(from: from, to: to):
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            let directory = to.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try fileManager.copyItem(at: from, to: to)
        case let .write(url: url, data: data):
            try data.write(to: url)
        }
        return .empty
    }
}

#endif
