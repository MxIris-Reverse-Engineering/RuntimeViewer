#if os(macOS)

import AppKit
import SwiftUI

struct SimulatorInstallerInstallSection: View {
    @Bindable var viewModel: SimulatorInstallerViewModel

    var body: some View {
        Section("Install") {
            Picker("RuntimeViewer.app", selection: $viewModel.selectedArtifactID) {
                if viewModel.artifacts.isEmpty {
                    Text("No downloaded simulator apps")
                        .tag(Optional<SimulatorRuntimeViewerArtifact.ID>.none)
                } else {
                    ForEach(viewModel.artifacts) { artifact in
                        Text(artifact.displayName)
                            .tag(Optional(artifact.id))
                    }
                }
            }
            .disabled(viewModel.artifacts.isEmpty || viewModel.isInstalling)

            HStack {
                Spacer()

                Button("Reveal", systemImage: "folder", action: revealSelectedArtifact)
                    .disabled(viewModel.selectedArtifact == nil)

                Button(
                    "Delete",
                    systemImage: "trash",
                    role: .destructive,
                    action: viewModel.deleteSelectedArtifact
                )
                .disabled(viewModel.selectedArtifact == nil || viewModel.isDownloading)
            }

            Picker("Simulator", selection: $viewModel.selectedSimulatorID) {
                if viewModel.simulators.isEmpty {
                    Text("No available simulators")
                        .tag(Optional<RuntimeViewerSimulatorDevice.ID>.none)
                } else {
                    ForEach(viewModel.simulators) { simulator in
                        Text(simulator.displayName)
                            .tag(Optional(simulator.id))
                    }
                }
            }
            .disabled(viewModel.simulators.isEmpty || viewModel.isInstalling)

            HStack {
                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise", action: refreshSimulators)
                    .disabled(viewModel.isInstalling)

                Button(
                    "Install",
                    systemImage: "iphone.and.arrow.forward",
                    action: viewModel.installSelectedArtifact
                )
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canInstall)
            }

            Text(viewModel.installStatus)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func refreshSimulators() {
        Task {
            await viewModel.refreshSimulators()
        }
    }

    private func revealSelectedArtifact() {
        guard let artifact = viewModel.selectedArtifact else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.appURL])
    }
}

#endif
