#if os(macOS)

import Foundation

final class SimulatorRuntimeViewerInstallerService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static func normalizedVersion(_ version: String) -> String {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVersion.lowercased().hasPrefix("v") {
            return String(trimmedVersion.dropFirst())
        }
        return trimmedVersion
    }

    func releaseAssetURL(for version: String) throws -> URL {
        let normalizedVersion = Self.normalizedVersion(version)
        guard !normalizedVersion.isEmpty else {
            throw SimulatorRuntimeViewerInstallerError.invalidVersion
        }
        let urlString = "https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/download/v\(normalizedVersion)/RuntimeViewer-iOS-Simulator.zip"
        guard let url = URL(string: urlString) else {
            throw SimulatorRuntimeViewerInstallerError.invalidReleaseURL(urlString)
        }
        return url
    }

    func listDownloadedArtifacts() throws -> [SimulatorRuntimeViewerArtifact] {
        let rootDirectory = try simulatorAppsRootDirectory()
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }

        let versionDirectories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let artifacts = versionDirectories.compactMap { directory -> SimulatorRuntimeViewerArtifact? in
            guard directory.isDirectory else { return nil }
            guard let appURL = try? findRuntimeViewerApp(in: directory) else { return nil }

            let directoryName = directory.lastPathComponent
            let version = directoryName.lowercased().hasPrefix("v")
                ? String(directoryName.dropFirst())
                : directoryName
            let downloadedAt = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            return SimulatorRuntimeViewerArtifact(version: version, appURL: appURL, downloadedAt: downloadedAt)
        }

        return artifacts.sorted { lhs, rhs in
            lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
        }
    }

    func downloadSimulatorApp(
        version: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SimulatorRuntimeViewerArtifact {
        let normalizedVersion = Self.normalizedVersion(version)
        guard !normalizedVersion.isEmpty else {
            throw SimulatorRuntimeViewerInstallerError.invalidVersion
        }

        let releaseURL = try releaseAssetURL(for: normalizedVersion)
        progress(0)

        let temporaryZipURL = try await DownloadJob(progress: progress).start(url: releaseURL)
        defer {
            try? fileManager.removeItem(at: temporaryZipURL)
        }

        let versionDirectory = try simulatorAppsRootDirectory()
            .appendingPathComponent("v\(normalizedVersion)", isDirectory: true)
        if fileManager.fileExists(atPath: versionDirectory.path) {
            try fileManager.removeItem(at: versionDirectory)
        }
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)

        let zipURL = versionDirectory.appendingPathComponent("RuntimeViewer-iOS-Simulator.zip")
        try fileManager.moveItem(at: temporaryZipURL, to: zipURL)

        let extractedDirectory = versionDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)

        try await runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", zipURL.path, extractedDirectory.path]
        )

        let appURL = try findRuntimeViewerApp(in: extractedDirectory)
        progress(1)

        return SimulatorRuntimeViewerArtifact(version: normalizedVersion, appURL: appURL, downloadedAt: Date())
    }

    func deleteArtifact(_ artifact: SimulatorRuntimeViewerArtifact) throws {
        let versionDirectory = try simulatorAppsRootDirectory()
            .appendingPathComponent("v\(artifact.version)", isDirectory: true)
        if fileManager.fileExists(atPath: versionDirectory.path) {
            try fileManager.removeItem(at: versionDirectory)
        }
    }

    func listAvailableSimulators() async throws -> [RuntimeViewerSimulatorDevice] {
        let output = try await runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "-j"]
        )

        let payload = try JSONDecoder().decode(SimctlDeviceList.self, from: Data(output.utf8))
        let devices = payload.devices.flatMap { runtimeIdentifier, devices in
            devices.compactMap { device -> RuntimeViewerSimulatorDevice? in
                if let isAvailable = device.isAvailable, !isAvailable { return nil }
                return RuntimeViewerSimulatorDevice(
                    name: device.name,
                    udid: device.udid,
                    runtimeName: Self.displayName(forRuntimeIdentifier: runtimeIdentifier),
                    state: device.state
                )
            }
        }

        return devices.sorted { lhs, rhs in
            if lhs.runtimeName == rhs.runtimeName {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.runtimeName.localizedStandardCompare(rhs.runtimeName) == .orderedDescending
        }
    }

    func install(_ artifact: SimulatorRuntimeViewerArtifact, on simulator: RuntimeViewerSimulatorDevice) async throws {
        guard fileManager.fileExists(atPath: artifact.appURL.path) else {
            throw SimulatorRuntimeViewerInstallerError.missingApp(artifact.appURL.path)
        }

        try await runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "install", simulator.udid, artifact.appURL.path]
        )
    }

    private func simulatorAppsRootDirectory() throws -> URL {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rootDirectory = applicationSupportURL
            .appendingPathComponent("RuntimeViewer", isDirectory: true)
            .appendingPathComponent("SimulatorApps", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        return rootDirectory
    }

    private func findRuntimeViewerApp(in directory: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw SimulatorRuntimeViewerInstallerError.missingApp(directory.path)
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "app", url.lastPathComponent == "RuntimeViewer.app" else { continue }
            guard url.isDirectory else { continue }
            return url
        }

        throw SimulatorRuntimeViewerInstallerError.missingApp(directory.path)
    }

    @discardableResult
    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let standardOutput = Pipe()
            let standardError = Pipe()
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            process.waitUntilExit()

            let output = String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let errorOutput = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            guard process.terminationStatus == 0 else {
                throw SimulatorRuntimeViewerInstallerError.commandFailed(
                    executable: executable,
                    arguments: arguments,
                    output: output,
                    errorOutput: errorOutput
                )
            }

            return output
        }.value
    }

    private static func displayName(forRuntimeIdentifier runtimeIdentifier: String) -> String {
        guard let rawRuntimeName = runtimeIdentifier.split(separator: ".").last else {
            return runtimeIdentifier
        }

        let runtimeName = String(rawRuntimeName)
        let knownPrefixes = ["iOS-", "tvOS-", "watchOS-", "visionOS-"]
        for prefix in knownPrefixes where runtimeName.hasPrefix(prefix) {
            let platform = String(prefix.dropLast())
            let version = runtimeName.dropFirst(prefix.count).replacingOccurrences(of: "-", with: ".")
            return "\(platform) \(version)"
        }
        return runtimeName.replacingOccurrences(of: "-", with: " ")
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private struct SimctlDeviceList: Decodable {
    let devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool?
}

private enum SimulatorRuntimeViewerInstallerError: LocalizedError {
    case invalidVersion
    case invalidReleaseURL(String)
    case unexpectedDownloadStatus(Int)
    case missingApp(String)
    case commandFailed(executable: String, arguments: [String], output: String, errorOutput: String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            return "Enter a RuntimeViewer version."
        case .invalidReleaseURL(let urlString):
            return "Invalid release URL: \(urlString)"
        case .unexpectedDownloadStatus(let statusCode):
            return "GitHub returned HTTP \(statusCode) for the simulator app download."
        case .missingApp(let path):
            return "RuntimeViewer.app was not found in \(path)."
        case .commandFailed(let executable, let arguments, let output, let errorOutput):
            let message = errorOutput.isEmpty ? output : errorOutput
            return "Command failed: \(([executable] + arguments).joined(separator: " "))\n\(message)"
        }
    }
}

private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
        super.init()
    }

    func start(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                }

                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session

                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            finish(.failure(SimulatorRuntimeViewerInstallerError.unexpectedDownloadStatus(response.statusCode)))
            return
        }

        do {
            let stableURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RuntimeViewer-\(UUID().uuidString)")
                .appendingPathExtension("zip")
            try FileManager.default.copyItem(at: location, to: stableURL)
            finish(.success(stableURL))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
    }

    private func cancel() {
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }

        session?.finishTasksAndInvalidate()

        guard let continuation else { return }
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

#endif
