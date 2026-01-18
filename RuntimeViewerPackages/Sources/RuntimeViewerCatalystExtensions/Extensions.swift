import RuntimeViewerCommunication

extension RuntimeSource {
    public static let macCatalystClient: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client)
    public static let macCatalystServer: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .server)
}

extension RuntimeSource.Identifier {
    public static let macCatalyst: Self = "com.RuntimeViewer.RuntimeSource.MacCatalyst"
}
