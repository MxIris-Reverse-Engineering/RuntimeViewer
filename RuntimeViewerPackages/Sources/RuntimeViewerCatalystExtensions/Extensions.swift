import RuntimeViewerCommunication

extension RuntimeSource {
    public static let macCatalystClient: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client)
    public static let macCatalystServer: Self = .remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .server)
}

// `RuntimeSource.Identifier.macCatalyst` is declared in RuntimeViewerCommunication
// alongside the Identifier type: the connection layer keys the injected-endpoint
// registry announcement on it, so it cannot live up here.
