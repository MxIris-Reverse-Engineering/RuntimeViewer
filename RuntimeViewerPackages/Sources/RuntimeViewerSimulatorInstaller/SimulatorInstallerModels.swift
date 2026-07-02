#if os(macOS)

import Foundation

struct SimulatorRuntimeViewerArtifact: Identifiable, Equatable {
    let version: String
    let appURL: URL
    let downloadedAt: Date?

    var id: String {
        appURL.standardizedFileURL.path
    }

    var displayName: String {
        "v\(version) - RuntimeViewer.app"
    }

    var locationDisplay: String {
        appURL.deletingLastPathComponent().path
    }
}

struct RuntimeViewerSimulatorDevice: Identifiable, Equatable {
    let name: String
    let udid: String
    let runtimeName: String
    let state: String

    var id: String {
        udid
    }

    var displayName: String {
        "\(name) (\(runtimeName), \(state))"
    }
}

#endif
