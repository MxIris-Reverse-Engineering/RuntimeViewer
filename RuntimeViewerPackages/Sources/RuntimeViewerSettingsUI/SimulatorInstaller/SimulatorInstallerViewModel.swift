#if os(macOS)

import AppKit
import Foundation

@MainActor
final class SimulatorInstallerViewModel: ObservableObject {
    let currentVersion: String

    @Published var version: String
    @Published private(set) var artifacts: [SimulatorRuntimeViewerArtifact] = []
    @Published private(set) var simulators: [RuntimeViewerSimulatorDevice] = []
    @Published private(set) var selectedArtifactID: SimulatorRuntimeViewerArtifact.ID?
    @Published private(set) var selectedSimulatorID: RuntimeViewerSimulatorDevice.ID?
    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalling = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadStatus = "Ready"
    @Published private(set) var installStatus = "Choose a simulator and a downloaded RuntimeViewer.app."

    private let service: SimulatorRuntimeViewerInstallerService
    private var downloadTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    init(service: SimulatorRuntimeViewerInstallerService = SimulatorRuntimeViewerInstallerService()) {
        self.service = service
        currentVersion = service.currentAppVersion
        version = currentVersion
    }

    var selectedArtifact: SimulatorRuntimeViewerArtifact? {
        artifacts.first { $0.id == selectedArtifactID }
    }

    var selectedSimulator: RuntimeViewerSimulatorDevice? {
        simulators.first { $0.id == selectedSimulatorID }
    }

    var canDownload: Bool {
        !isDownloading && !SimulatorRuntimeViewerInstallerService.normalizedVersion(version).isEmpty
    }

    var canInstall: Bool {
        !isInstalling && selectedArtifact != nil && selectedSimulator != nil
    }

    func refresh() {
        Task {
            refreshArtifacts()
            await refreshSimulators()
        }
    }

    func refreshArtifacts() {
        do {
            artifacts = try service.listDownloadedArtifacts()
            if let selectedArtifactID, artifacts.contains(where: { $0.id == selectedArtifactID }) {
                self.selectedArtifactID = selectedArtifactID
            } else {
                selectedArtifactID = artifacts.first?.id
            }
            if artifacts.isEmpty {
                installStatus = "Download a simulator app before installing."
            }
        } catch {
            downloadStatus = error.localizedDescription
        }
    }

    func refreshSimulators() async {
        do {
            simulators = try await service.listAvailableSimulators()
            if let selectedSimulatorID, simulators.contains(where: { $0.id == selectedSimulatorID }) {
                self.selectedSimulatorID = selectedSimulatorID
            } else {
                selectedSimulatorID = simulators.first?.id
            }
            if simulators.isEmpty {
                installStatus = "No available simulators found."
            }
        } catch {
            installStatus = error.localizedDescription
        }
    }

    func selectArtifact(id: SimulatorRuntimeViewerArtifact.ID?) {
        selectedArtifactID = id
    }

    func selectSimulator(id: RuntimeViewerSimulatorDevice.ID?) {
        selectedSimulatorID = id
    }

    func resetVersion() {
        version = currentVersion
    }

    func downloadSelectedVersion() {
        guard canDownload else { return }

        let requestedVersion = version
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Downloading v\(SimulatorRuntimeViewerInstallerService.normalizedVersion(requestedVersion))..."

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await service.downloadSimulatorApp(version: requestedVersion) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadProgress = progress
                        self.downloadStatus = "Downloading \(Int((progress * 100).rounded()))%"
                    }
                }

                artifacts = try service.listDownloadedArtifacts()
                selectedArtifactID = artifact.id
                downloadProgress = 1
                downloadStatus = "Downloaded v\(artifact.version)."
                if selectedSimulator == nil {
                    installStatus = "Choose a simulator."
                } else {
                    installStatus = "Ready to install v\(artifact.version)."
                }
            } catch is CancellationError {
                downloadStatus = "Download cancelled."
            } catch {
                downloadStatus = error.localizedDescription
            }

            isDownloading = false
        }
    }

    func deleteSelectedArtifact() {
        guard let artifact = selectedArtifact else { return }

        do {
            try service.deleteArtifact(artifact)
            refreshArtifacts()
            downloadStatus = "Deleted v\(artifact.version)."
        } catch {
            downloadStatus = error.localizedDescription
        }
    }

    func installSelectedArtifact() {
        guard let selectedArtifact, let selectedSimulator else { return }

        isInstalling = true
        installStatus = "Installing v\(selectedArtifact.version) to \(selectedSimulator.name)..."

        installTask?.cancel()
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.install(selectedArtifact, on: selectedSimulator)
                installStatus = "Installed v\(selectedArtifact.version) on \(selectedSimulator.name)."
            } catch is CancellationError {
                installStatus = "Install cancelled."
            } catch {
                installStatus = error.localizedDescription
            }

            isInstalling = false
        }
    }
}

#endif
