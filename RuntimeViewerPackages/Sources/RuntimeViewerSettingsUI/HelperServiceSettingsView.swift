#if os(macOS)

import SwiftUI
import SettingsKit
import ServiceManagement
import RuntimeViewerHelperClient
import Dependencies

// MARK: - UI Helper Extensions

extension SMAppService.Status {
    var icon: String {
        switch self {
        case .enabled:
            return "checkmark.circle.fill"
        case .requiresApproval:
            return "exclamationmark.triangle.fill"
        case .notRegistered, .notFound:
            return "xmark.circle.fill"
        @unknown default:
            return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .notRegistered, .notFound:
            return .secondary
        @unknown default:
            return .secondary
        }
    }
}

// MARK: - Settings View

struct HelperServiceSettingsView: SettingsContent {
    @Dependency(\.helperServiceManager) private var manager

    var body: some SettingsContent {
        SettingsGroup("Helper", .navigation) {
            SettingsForm {
                if manager.isLegacyServiceInstalled {
                    Section {
                        LegacyServiceStatusRow()
                    } header: {
                        Text("Legacy Helper Service")
                    } footer: {
                        Text("The legacy helper service uses deprecated APIs. Please uninstall it and install the new version for better stability and security.")
                    }
                }

                Section {
                    HelperServiceStatusRow()
                } header: {
                    Text("Helper Service")
                } footer: {
                    Text("The helper service enables advanced features such as code injection and accessing system-protected processes.")
                }

                Section {
                    QuickActionsRow()
                } header: {
                    Text("Quick Actions")
                }
            }
            .task {
                await manager.refreshAllStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { @MainActor in
                    await manager.refreshAllStatus()
                }
            }
        } icon: {
            SettingsIcon(symbol: "wrench.and.screwdriver", color: .clear)
        }
    }
}

// MARK: - Legacy Service Status Row

private struct LegacyServiceStatusRow: View {
    @Dependency(\.helperServiceManager) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: manager.isLegacyServiceInstalled ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(manager.isLegacyServiceInstalled ? .orange : .green)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Legacy Version Detected")
                        .font(.headline)
                    Text(manager.legacyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if manager.isLegacyLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Uninstall", role: .destructive) {
                        Task {
                            await manager.uninstallLegacyService()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!manager.canUninstallLegacy)
                    .help(manager.canUninstallLegacy ? "Uninstall the legacy helper service" : "Install the new helper service first")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helper Service Status Row

private struct HelperServiceStatusRow: View {
    @Dependency(\.helperServiceManager) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: manager.status.icon)
                    .foregroundStyle(manager.status.color)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Helper Service")
                        .font(.headline)
                    Text(manager.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if manager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ServiceActionButtons()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Service Action Buttons

private struct ServiceActionButtons: View {
    @Dependency(\.helperServiceManager) private var manager

    var body: some View {
        HStack(spacing: 8) {
            switch manager.status {
            case .enabled:
                Button("Uninstall", role: .destructive) {
                    Task {
                        await manager.manageHelperService(action: .uninstall)
                    }
                }
                .buttonStyle(.bordered)

            case .requiresApproval:
                Button("Open Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .buttonStyle(.borderedProminent)

            case .notRegistered, .notFound:
                Button("Install") {
                    Task {
                        await manager.manageHelperService(action: .install)
                    }
                }
                .buttonStyle(.borderedProminent)

            @unknown default:
                Button("Refresh") {
                    Task {
                        await manager.manageHelperService(action: .status)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Quick Actions Row

private struct QuickActionsRow: View {
    @Dependency(\.helperServiceManager) private var manager

    var body: some View {
        HStack {
            Button {
                Task {
                    await manager.refreshAllStatus()
                }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }

            Spacer()

            Button {
                SMAppService.openSystemSettingsLoginItems()
            } label: {
                Label("Open Login Items Settings", systemImage: "gear")
            }
        }
    }
}

#endif
