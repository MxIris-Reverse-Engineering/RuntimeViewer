import Foundation
// `RuntimeSource` and `RuntimeRemoteEngineDescriptor` are re-exported because
// both appear in this file's public API.
public import RuntimeViewerCommunication

/// The stable persistence identity of one inspected peer.
///
/// Everything the app keys on a peer goes through this type: the bookmark
/// dictionaries and the sidebar's `NSOutlineView` autosave state. It exists to
/// make one rule impossible to bypass — a persistence key may never be built
/// from a *display name*, nor from anything carrying a process identifier.
/// A display name collides between two peers that happen to share one, and a
/// pid-bearing key changes on every relaunch of the peer, silently losing the
/// previous run's data and leaving a dead entry behind each time.
///
/// Both mistakes were live in three separate places before this type existed,
/// each having independently reached for whatever string was nearest. See
/// `Documentations/Evolutions/draft-runtime-bookmark-scope.md`.
///
/// Lives here, beside ``RuntimeImageBookmark`` and ``RuntimeObjectBookmark``,
/// rather than beside `RuntimeSource` in `RuntimeViewerCommunication`. It is
/// derived from a source, but what it *is* is an application-level persistence
/// key, and the communication layer has no business knowing that bookmarks
/// exist. Every target that reaches for a scope already depends on this
/// module.
public enum RuntimeBookmarkScope: Sendable, Hashable {
    /// A scope built from an identity that survives the peer relaunching.
    case identified(Identity)

    /// No stable identity was available, so the two consumers fall back
    /// separately.
    ///
    /// They must not share one string. The bookmark key falls back to
    /// ``RuntimeSource/identifier``, which is where bookmark keys already came
    /// from, so the fallback changes nothing. The sidebar key falls back to the
    /// *display name*, because the sidebar's alternative — the identifier — is
    /// the pid-bearing one, and adopting it would hand the sidebar the very
    /// accumulation this type exists to prevent.
    case legacy(bookmarkKey: String, sidebarAutosaveKey: String)
}

// MARK: - Identity

extension RuntimeBookmarkScope {
    /// The identity halves that a scope is composed of, one shape per source
    /// kind.
    ///
    /// Each kind contributes whatever stable identifier it *already* has,
    /// rather than being forced into a common shape. A `directTCP` peer has no
    /// device identifier at all, and inventing one for it would only produce a
    /// key that looks structured and means nothing.
    public enum Identity: Sendable, Hashable {
        case local
        case remote(identifier: String, role: RuntimeSource.Role)
        case localSocket(identifier: String, role: RuntimeSource.Role)

        /// Port first, host second — see ``rawValue`` for why the order is
        /// load-bearing.
        case directTCP(port: UInt16, host: String?, role: RuntimeSource.Role)

        /// A device identifier plus the advertising process's display name.
        ///
        /// This is as precise as the advertisement allows: the TXT record
        /// carries no bundle identifier, so two same-named processes on one
        /// device do share a scope. That is an accepted cost, not an oversight.
        case bonjour(deviceID: String, processName: String, role: RuntimeSource.Role)
    }
}

extension RuntimeBookmarkScope.Identity {
    /// The source kind an identity was built from, as it appears in
    /// ``RuntimeBookmarkScope/Identity/rawValue``.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case local
        case remote
        case localSocket
        case directTCP
        case bonjour
    }

    public var kind: Kind {
        switch self {
        case .local: .local
        case .remote: .remote
        case .localSocket: .localSocket
        case .directTCP: .directTCP
        case .bonjour: .bonjour
        }
    }

    public var role: RuntimeSource.Role? {
        switch self {
        case .local: nil
        case .remote(_, let role), .localSocket(_, let role): role
        case .directTCP(_, _, let role), .bonjour(_, _, let role): role
        }
    }
}

// MARK: - On-disk representation

extension RuntimeBookmarkScope.Identity: RawRepresentable, CustomStringConvertible {
    /// Prefix carried by every identity written to disk.
    ///
    /// Not speculative generality: the device identifier embedded in a
    /// `.bonjour` identity is a raw UDID today, and the pending privacy work
    /// replaces it with a salted hash. That will change every `.bonjour` key on
    /// disk, and a version prefix is what makes the change a migration with
    /// something to migrate *from* rather than one more silent wipe.
    public static let formatVersion = "v1"

    private static let segmentSeparator: Character = ":"

    /// The readable, reverse-parsable string this identity is stored as.
    ///
    /// Segment order is fixed at `<version>:<kind>:<role>:<remainder>`. The
    /// first three segments are drawn from literal sets this project defines,
    /// so none of them can contain a separator. The remainder is defined per
    /// kind, and every sub-segment but the last is likewise separator-free —
    /// **the last sub-segment swallows the rest of the string** and is never
    /// split further. That is what removes the need for escaping:
    ///
    /// - `.bonjour` → `<deviceID>:<processName>`. A device identifier is
    ///   UUID-shaped; a process display name is arbitrary and may well contain
    ///   a colon, spaces or non-ASCII, so it takes the swallowing position.
    /// - `.directTCP` → `<port>:<host>`. Port leads *because* a host can be a
    ///   bracket-less IPv6 literal, which is nothing but colons; a port is
    ///   pure digits and cannot be mistaken for one.
    /// - `.remote` / `.localSocket` → the identifier, whole, swallowing.
    /// - `.local` → empty.
    public var rawValue: String {
        let separator = String(Self.segmentSeparator)
        return [Self.formatVersion, kind.rawValue, role.roleToken, remainder].joined(separator: separator)
    }

    public var description: String { rawValue }

    /// The kind-specific tail of ``rawValue``.
    private var remainder: String {
        switch self {
        case .local:
            return ""
        case .remote(let identifier, _), .localSocket(let identifier, _):
            return identifier
        case .directTCP(let port, let host, _):
            // A nil host encodes as empty. The two are not distinguishable on
            // the way back, which costs nothing: `RuntimeSource.directTCP`
            // carries nil for a server (there is no host to connect *to*) and a
            // non-empty host otherwise. An empty-string host never occurs.
            return "\(port)\(Self.segmentSeparator)\(host ?? "")"
        case .bonjour(let deviceID, let processName, _):
            return "\(deviceID)\(Self.segmentSeparator)\(processName)"
        }
    }

    public init?(rawValue: String) {
        let segments = rawValue.split(
            separator: Self.segmentSeparator,
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard segments.count == 4,
              segments[0] == Self.formatVersion,
              let kind = Kind(rawValue: String(segments[1]))
        else { return nil }

        let roleToken = String(segments[2])
        let remainder = String(segments[3])

        switch kind {
        case .local:
            guard roleToken.isEmpty, remainder.isEmpty else { return nil }
            self = .local

        case .remote, .localSocket:
            guard let role = RuntimeSource.Role(roleToken: roleToken), !remainder.isEmpty else { return nil }
            self = kind == .remote
                ? .remote(identifier: remainder, role: role)
                : .localSocket(identifier: remainder, role: role)

        case .directTCP:
            guard let role = RuntimeSource.Role(roleToken: roleToken) else { return nil }
            let parts = remainder.split(
                separator: Self.segmentSeparator,
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2, let port = UInt16(parts[0]) else { return nil }
            let host = parts[1].isEmpty ? nil : String(parts[1])
            self = .directTCP(port: port, host: host, role: role)

        case .bonjour:
            guard let role = RuntimeSource.Role(roleToken: roleToken) else { return nil }
            let parts = remainder.split(
                separator: Self.segmentSeparator,
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            self = .bonjour(deviceID: String(parts[0]), processName: String(parts[1]), role: role)
        }
    }

    /// The device identifier segment of a stored `.bonjour` key, without
    /// decoding the rest.
    ///
    /// This is the hook the version prefix was added for: migrating `v1` to a
    /// hashed-UDID `v2` has to reach exactly this segment and nothing else.
    /// Returns `nil` for any other kind, and for anything that is not a `v1`
    /// key at all — including a `legacy` key, which is stored verbatim and
    /// carries no version prefix.
    public static func deviceIdentifier(inRawValue rawValue: String) -> String? {
        guard case .bonjour(let deviceID, _, _) = Self(rawValue: rawValue) else { return nil }
        return deviceID
    }
}

extension RuntimeSource.Role {
    fileprivate var token: String {
        switch self {
        case .client: "client"
        case .server: "server"
        }
    }

    fileprivate init?(roleToken: String) {
        switch roleToken {
        case "client": self = .client
        case "server": self = .server
        default: return nil
        }
    }
}

extension Optional<RuntimeSource.Role> {
    /// An absent role encodes as empty, which only `.local` ever produces.
    fileprivate var roleToken: String { self?.token ?? "" }
}

// MARK: - Consumer keys

extension RuntimeBookmarkScope {
    /// The key a bookmark dictionary stores this peer's entries under.
    public var bookmarkKey: String {
        switch self {
        case .identified(let identity): identity.rawValue
        case .legacy(let bookmarkKey, _): bookmarkKey
        }
    }

    /// The peer-specific suffix of the sidebar's `NSOutlineView` identifier and
    /// autosave names.
    public var sidebarAutosaveKey: String {
        switch self {
        case .identified(let identity): identity.rawValue
        case .legacy(_, let sidebarAutosaveKey): sidebarAutosaveKey
        }
    }

    /// The stored form of this scope's identity, or `nil` when there is none to
    /// send. Used to put the identity on the wire in
    /// ``RuntimeRemoteEngineDescriptor``.
    public var identityRawValue: String? {
        guard case .identified(let identity) = self else { return nil }
        return identity.rawValue
    }
}

// MARK: - Wire transport

extension RuntimeRemoteEngineDescriptor {
    /// The scope a mirror of this engine files its bookmarks and sidebar state
    /// under.
    ///
    /// A mirror connects over a proxy whose `directTCP` host and port are
    /// assigned per session, so deriving a scope from the *mirror's* own source
    /// would produce a key that changes on every reconnect. The identity has to
    /// come from the peer that owns the engine, which is why it travels on the
    /// descriptor.
    public var bookmarkScope: RuntimeBookmarkScope {
        if let identity = RuntimeBookmarkScope.Identity(rawValue: bookmarkScopeIdentity) {
            return .identified(identity)
        }
        // Either the peer predates the field, or it sent something this version
        // cannot parse. Both land here, and both recover from `source` — the
        // descriptor's own, describing the mirrored engine, never the proxy.
        return RuntimeBookmarkScope.recovered(from: source) ?? .legacy(for: source)
    }
}

// MARK: - Construction

extension RuntimeBookmarkScope {
    /// The fallback for a peer whose identity could not be established.
    ///
    /// See ``legacy(bookmarkKey:sidebarAutosaveKey:)`` for why the two keys
    /// come from different properties.
    public static func legacy(for source: RuntimeSource) -> RuntimeBookmarkScope {
        .legacy(bookmarkKey: source.identifier, sidebarAutosaveKey: source.description)
    }

    /// The scope of a Bonjour peer discovered on this host, built from the TXT
    /// record fields the peer publishes.
    ///
    /// Returns `nil` when the peer publishes no device identifier — a peer
    /// predating those keys — which the caller resolves by falling back to
    /// ``legacy(for:)``.
    ///
    /// `processName` must be the same string the engine's `RuntimeSource` was
    /// named with, i.e. `endpoint.processName ?? endpoint.name`. Passing
    /// anything else would put a directly-connected engine in a different scope
    /// from the one ``recovered(from:)`` derives for the same peer, and the two
    /// have to agree — that equivalence is what lets bookmarks migrated off
    /// disk be found again by a running engine.
    public static func bonjour(
        deviceID: String?,
        processName: String,
        role: RuntimeSource.Role
    ) -> RuntimeBookmarkScope? {
        guard let deviceID, !deviceID.isEmpty else { return nil }
        return .identified(.bonjour(deviceID: deviceID, processName: processName, role: role))
    }

    /// Recovers a scope from a `RuntimeSource` alone.
    ///
    /// Two callers have nothing else to go on and **must** agree, or bookmarks
    /// migrated off disk land under one key while the running engine reads
    /// another:
    ///
    /// - a mirrored engine whose descriptor predates the identity field;
    /// - the one-time migration of the bookmark dictionaries.
    ///
    /// Returns `nil` only for a `.bonjour` source whose identifier carries no
    /// device identity; every other kind already holds a stable identifier and
    /// maps across one-to-one.
    public static func recovered(from source: RuntimeSource) -> RuntimeBookmarkScope? {
        switch source {
        case .local:
            return .identified(.local)

        case .remote(_, let identifier, let role):
            return .identified(.remote(identifier: identifier.rawValue, role: role))

        case .localSocket(_, let identifier, let role):
            return .identified(.localSocket(identifier: identifier.rawValue, role: role))

        case .directTCP(_, let host, let port, let role):
            return .identified(.directTCP(port: port, host: host, role: role))

        case .bonjour(let name, let identifier, let role):
            // A server-role Bonjour source is this app's own advertisement, and
            // its identifier is the service name rather than a device key.
            // Falling through to the gate below rejects it, which is correct:
            // that engine is the broadcast end, not something a user browses.
            guard let deviceID = deviceIdentifier(ofBonjourClientIdentifier: identifier.rawValue) else { return nil }
            // `name` is used whole, deliberately. The gate above only opens for
            // a `{deviceID}-{processIdentifier}` identifier, a shape that only
            // exists on keys written after the simulator-injection work landed,
            // and on those the name is by construction the same
            // `endpoint.processName ?? endpoint.name` that a live engine is
            // built from. Parsing a `"device (process)"` shape out of it — the
            // rule this proposal was drafted with — would instead *reject* the
            // common case, where the peer does publish a process name and the
            // engine is named with it alone.
            return .identified(.bonjour(deviceID: deviceID, processName: name, role: role))
        }
    }

    /// Splits a Bonjour client identifier of the form
    /// `{deviceID}-{processIdentifier}` back into its device half.
    ///
    /// This is the gate the whole recovery path hangs on. An identifier
    /// predating that format is a *service name*: it carries no device identity
    /// whatsoever, and taking one for a device identifier would file bookmarks
    /// under a scope no running engine ever produces.
    ///
    /// A device identifier is itself UUID-shaped and full of hyphens, so the
    /// split is anchored at the *last* one — and the tail has to look like a
    /// process identifier and nothing else.
    ///
    /// "Entirely digits" is not enough on its own: a UUID's final group is
    /// twelve hex characters, which are all decimal digits about one time in
    /// two hundred, and accepting one would silently file the peer under a
    /// truncated device identifier. Requiring the tail to be the exact decimal
    /// spelling of a positive `Int32` rules that out for good — twelve digits
    /// overflow `pid_t`, and a leading-zero group never matches the spelling
    /// `ProcessInfo.processIdentifier.description` produces.
    static func deviceIdentifier(ofBonjourClientIdentifier identifier: String) -> String? {
        guard let separatorIndex = identifier.lastIndex(of: "-") else { return nil }
        let processIdentifierPart = identifier[identifier.index(after: separatorIndex)...]
        guard let processIdentifier = Int32(processIdentifierPart),
              processIdentifier > 0,
              String(processIdentifier) == processIdentifierPart
        else { return nil }
        let deviceIdentifierPart = identifier[..<separatorIndex]
        guard !deviceIdentifierPart.isEmpty else { return nil }
        return String(deviceIdentifierPart)
    }
}
