#if os(macOS)

import SwiftUI

struct SimulatorInstallerVersionSection: View {
    @Bindable var viewModel: SimulatorInstallerViewModel

    var body: some View {
        Section("Version") {
            LabeledContent("Current Version", value: viewModel.currentVersion)
            LabeledContent("Download Version") {
                HStack(spacing: 8) {
                    TextField("Version", text: $viewModel.version)
                        .textFieldStyle(.roundedBorder)
                        .disabled(viewModel.isDownloading)
                        .frame(maxWidth: 220)

                    Button(
                        "Reset",
                        systemImage: "arrow.counterclockwise",
                        action: viewModel.resetVersion
                    )
                    .disabled(viewModel.isDownloading)
                }
            }
        }
    }
}

#endif
