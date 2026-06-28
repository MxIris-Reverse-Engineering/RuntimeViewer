#if os(macOS)

import SwiftUI

struct SimulatorInstallerDownloadSection: View {
    @Bindable var viewModel: SimulatorInstallerViewModel

    var body: some View {
        Section("Download") {
            HStack(spacing: 12) {
                Button(
                    "Download",
                    systemImage: "arrow.down.circle",
                    action: viewModel.downloadSelectedVersion
                )
                .disabled(!viewModel.canDownload)

                ProgressView(value: viewModel.downloadProgress ?? 0, total: 1)
                    .frame(maxWidth: .infinity)
                    .opacity(viewModel.downloadProgress == nil ? 0.35 : 1)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(downloadProgressAccessibilityValue)
            }

            Text(viewModel.downloadStatus)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var downloadProgressAccessibilityValue: String {
        guard let downloadProgress = viewModel.downloadProgress else {
            return "Not started"
        }

        return "\(Int((downloadProgress * 100).rounded())) percent"
    }
}

#endif
