#if os(macOS)

import SwiftUI

struct SimulatorInstallerView: View {
    @Bindable private var viewModel: SimulatorInstallerViewModel

    init(viewModel: SimulatorInstallerViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            SimulatorInstallerVersionSection(viewModel: viewModel)
            SimulatorInstallerDownloadSection(viewModel: viewModel)
            SimulatorInstallerInstallSection(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 390, idealHeight: 440)
        .task {
            viewModel.refresh()
        }
    }
}

#endif
