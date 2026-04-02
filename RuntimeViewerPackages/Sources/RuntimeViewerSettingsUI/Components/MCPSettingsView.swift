#if os(macOS)

import SwiftUI
import Dependencies
import RuntimeViewerSettings
import AppKit

struct MCPSettingsView: View {
    @AppSettings(\.mcp)
    var settings

    @State private var copied = false

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Enable MCP Server", isOn: $settings.isEnabled)
            } footer: {
                Text("When enabled, the MCP (Model Context Protocol) server allows LLM clients to inspect runtime information.")
            }

            Section {
                Toggle("Use Fixed Port", isOn: $settings.useFixedPort)
                    .disabled(!settings.isEnabled)

                if settings.useFixedPort {
                    LabeledContent {
                        TextField("", value: $settings.fixedPort, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .disabled(!settings.isEnabled)

                    } label: {
                        Text("Port")
                    }
                }
            } header: {
                Text("Port Configuration")
            } footer: {
                if settings.useFixedPort {
                    Text("The MCP server will listen on port \(settings.fixedPort). Changes take effect after restart.")
                } else {
                    Text("The MCP server will automatically assign an available port.")
                }
            }

            Section {
                CopyMCPConfigButton(copied: $copied, settings: settings)
            } header: {
                Text("Client Configuration")
            } footer: {
                Text("Copy the JSON configuration for use in MCP-compatible LLM clients (e.g., Claude).")
            }
        }
    }
}

// MARK: - Copy MCP Config Button

private struct CopyMCPConfigButton: View {
    @Binding var copied: Bool
    let settings: RuntimeViewerSettings.Settings.MCP

    var body: some View {
        HStack {
            Button {
                copyMCPConfig()
            } label: {
                Label(
                    copied ? "Copied!" : "Copy MCP JSON Configuration",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(!settings.isEnabled)

            Spacer()
        }
    }

    private func copyMCPConfig() {
        let port = resolvePort()

        let json: String
        if let port {
            json = """
            {
              "mcpServers": {
                "RuntimeViewer": {
                  "type": "http",
                  "url": "http://127.0.0.1:\(port)/mcp"
                }
              }
            }
            """
        } else {
            json = """
            {
              "mcpServers": {
                "RuntimeViewer": {
                  "type": "http",
                  "url": "http://127.0.0.1:<port>/mcp"
                }
              }
            }
            """
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)

        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func resolvePort() -> UInt16? {
        if settings.useFixedPort {
            return settings.fixedPort
        }
        // Read the auto-assigned port from port file
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let portFilePath = appSupportURL?
            .appendingPathComponent("RuntimeViewer")
            .appendingPathComponent(Settings.MCP.portFileName)
            .path
        guard let portFilePath,
              let content = try? String(contentsOfFile: portFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let port = UInt16(content) else {
            return nil
        }
        return port
    }
}

#endif
