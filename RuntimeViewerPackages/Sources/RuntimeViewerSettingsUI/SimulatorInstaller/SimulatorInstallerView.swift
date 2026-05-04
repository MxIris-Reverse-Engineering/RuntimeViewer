#if os(macOS)

import AppKit
import SwiftUI

struct SimulatorInstallerView: View {
    @StateObject private var viewModel: SimulatorInstallerViewModel

    init(viewModel: SimulatorInstallerViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current Version", value: viewModel.currentVersion)
                LabeledContent("Download Version") {
                    HStack(spacing: 8) {
                        TextField("Version", text: $viewModel.version)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isDownloading)
                            .frame(maxWidth: 220)

                        Button {
                            viewModel.resetVersion()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(viewModel.isDownloading)
                    }
                }
            } header: {
                Text("Version")
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        viewModel.downloadSelectedVersion()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!viewModel.canDownload)

                    ProgressView(value: viewModel.downloadProgress ?? 0, total: 1)
                        .frame(maxWidth: .infinity)
                        .opacity(viewModel.downloadProgress == nil ? 0.35 : 1)
                }

                Text(viewModel.downloadStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } header: {
                Text("Download")
            }

            Section {
                Picker("RuntimeViewer.app", selection: artifactSelection) {
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
                    Button {
                        revealSelectedArtifact()
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .disabled(viewModel.selectedArtifact == nil)

                    Button(role: .destructive) {
                        viewModel.deleteSelectedArtifact()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(viewModel.selectedArtifact == nil || viewModel.isDownloading)
                }

                Picker("Simulator", selection: simulatorSelection) {
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
                    Button {
                        Task {
                            await viewModel.refreshSimulators()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isInstalling)

                    Button {
                        viewModel.installSelectedArtifact()
                    } label: {
                        Label("Install", systemImage: "iphone.and.arrow.forward")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canInstall)
                }

                Text(viewModel.installStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } header: {
                Text("Install")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 390, idealHeight: 440)
        .task {
            viewModel.refresh()
        }
    }

    private var artifactSelection: Binding<SimulatorRuntimeViewerArtifact.ID?> {
        Binding {
            viewModel.selectedArtifactID
        } set: { id in
            viewModel.selectArtifact(id: id)
        }
    }

    private var simulatorSelection: Binding<RuntimeViewerSimulatorDevice.ID?> {
        Binding {
            viewModel.selectedSimulatorID
        } set: { id in
            viewModel.selectSimulator(id: id)
        }
    }

    private func revealSelectedArtifact() {
        guard let artifact = viewModel.selectedArtifact else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.appURL])
    }
}

#endif
