#if os(macOS)

import AppKit
import SwiftUI
import RuntimeViewerCore
import RuntimeViewerSettings
import UIFoundationSettingsUI

/// Settings › Offline Files: the dyld shared caches that files built for
/// other platforms read what they link from.
struct OfflineSettingsView: View {
    @AppSettings(\.offline)
    var offline

    /// Why the cache last chosen could not be registered.
    @State private var registrationFailure: String?

    var body: some View {
        SettingsForm {
            Section {
                if offline.dependencyCaches.isEmpty {
                    Text("No dyld shared caches registered.")
                        .foregroundStyle(.secondary)
                }
                ForEach(offline.dependencyCaches) { cache in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Self.platformDisplayName(cache.platformName)) \(cache.version) (\(cache.architecture))")
                            Text(cache.path)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(cache.path)
                        }
                        Spacer()
                        Button {
                            offline.dependencyCaches.removeAll { $0.id == cache.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this cache. Files already open keep reading from it until they are opened again.")
                    }
                }

                Button {
                    registerCache()
                } label: {
                    Label("Add Dyld Shared Cache…", systemImage: "plus.circle")
                }

                if let registrationFailure {
                    Text(registrationFailure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Dependency Caches")
            } footer: {
                Text("A file built for macOS or Mac Catalyst reads what it links from this Mac's dyld shared cache. A file built for another platform reads it from a cache registered here: of its platform's caches — a simulator's file pairs only with that simulator's — the oldest one no older than the SDK the file was built with, or the newest when all are older. With none registered for its platform, the file is read alone. The Dependency Cache menu at the end of the Offline Files section in the engine menu picks another for an open file.")
            }
        }
    }

    private func registerCache() {
        let panel = NSOpenPanel()
        panel.message = "Choose the main file of a dyld shared cache, such as dyld_shared_cache_arm64e."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true

        guard panel.runModal() == .OK, let chosenURL = panel.url else { return }
        do {
            let summary = try RuntimeDyldSharedCacheSummary(contentsOf: chosenURL)
            let cache = Settings.Offline.DependencyCache(summary: summary)
            registrationFailure = nil
            guard !offline.dependencyCaches.contains(where: { $0.path == cache.path }) else { return }
            offline.dependencyCaches.append(cache)
        } catch {
            registrationFailure = "\(chosenURL.lastPathComponent) was not added: \(error.localizedDescription)"
        }
    }

    /// `iOSSimulator` as `iOS Simulator`.
    static func platformDisplayName(_ platformName: String) -> String {
        switch platformName {
        case "macCatalyst": "Mac Catalyst"
        case "iOSSimulator": "iOS Simulator"
        case "tvOSSimulator": "tvOS Simulator"
        case "watchOSSimulator": "watchOS Simulator"
        case "visionOSSimulator": "visionOS Simulator"
        case "driverKit": "DriverKit"
        default: platformName
        }
    }
}

#endif
