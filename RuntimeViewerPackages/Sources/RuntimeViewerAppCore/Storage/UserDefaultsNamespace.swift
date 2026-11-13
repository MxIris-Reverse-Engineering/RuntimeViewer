import Foundation

/// Where an `AppDefaults` keeps the values it stores in user defaults rather
/// than in files: which defaults, and under which keys.
///
/// The app has exactly one namespace, ``standard``. Tests need many — one per
/// `AppDefaults` they build — that share nothing: not the values, and not the
/// key-value observation `AppDefaults.$options` is made of. While every
/// instance used the standard defaults, a test that changed the Generation
/// Options made every live Find session in every other test search again.
///
/// The isolated namespaces all live in one suite, ``isolatedSuiteName``, and
/// differ by key prefix. A suite per namespace would be simpler, but removing
/// a suite's persistent domain empties it without deleting its file from
/// `~/Library/Preferences`, so every test run would leave about a hundred
/// empty files behind. Key-value observation of user defaults is per key, so
/// a write in one namespace is not reported in another.
enum UserDefaultsNamespace {
    /// The standard defaults, keys unchanged. Never cleared by this type.
    case standard

    /// The isolated suite, every key prefixed with `keyPrefix`.
    case isolated(keyPrefix: String)

    var userDefaults: UserDefaults {
        switch self {
        case .standard:
            return .standard
        case .isolated:
            return Self.isolatedSuite
        }
    }

    /// The key a value called `name` is stored under in this namespace.
    func key(_ name: String) -> String {
        switch self {
        case .standard:
            return name
        case .isolated(let keyPrefix):
            return keyPrefix + name
        }
    }

    /// A namespace nothing else uses, named after this process so that a
    /// later process can tell it was left behind.
    static func makeIsolated() -> UserDefaultsNamespace {
        makeIsolated(owningProcessIdentifier: ProcessInfo.processInfo.processIdentifier)
    }

    /// A namespace nothing else uses, named after `owningProcessIdentifier`.
    ///
    /// Only separators that key-value observation reads as part of a key:
    /// a dot would make the prefixed key a key *path*, and `$options` would
    /// stop observing it.
    static func makeIsolated(owningProcessIdentifier: pid_t) -> UserDefaultsNamespace {
        let uniqueIdentifier = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return .isolated(keyPrefix: "\(isolatedKeyMarker)_\(owningProcessIdentifier)_\(uniqueIdentifier)_")
    }

    /// The keys this namespace holds a value under; `nil` for the standard
    /// defaults, whose keys this type neither tracks nor removes.
    var isolatedKeys: [String]? {
        guard case .isolated(let keyPrefix) = self else { return nil }
        let domain = Self.isolatedSuite.persistentDomain(forName: Self.isolatedSuiteName) ?? [:]
        return domain.keys.filter { key in key.hasPrefix(keyPrefix) }
    }

    /// Removes every value an isolated namespace holds, for its owner to call
    /// when it goes away. Does nothing to the standard defaults.
    func removeIsolatedValues() {
        for key in isolatedKeys ?? [] {
            Self.isolatedSuite.removeObject(forKey: key)
        }
    }

    // MARK: - The isolated suite

    static let isolatedSuiteName = "RuntimeViewer.AppDefaults.Isolated"

    /// The first component of every isolated key, ahead of the owning
    /// process's identifier.
    private static let isolatedKeyMarker = "Isolated"

    /// Opened on first use, once per process, after sweeping out what ended
    /// processes left: a namespace is normally emptied when its owner goes
    /// away, but an owner that is never released — the test fallback, a
    /// leaked view model, a crashed run — keeps its values until then.
    private static let isolatedSuite: UserDefaults = {
        guard let suite = UserDefaults(suiteName: isolatedSuiteName) else {
            preconditionFailure("\(isolatedSuiteName) cannot name a user defaults suite")
        }
        removeNamespacesOfEndedProcesses(in: suite)
        return suite
    }()

    /// Removes the values of every namespace whose process is no longer
    /// running. Namespaces of running processes — this one, or another test
    /// run going on at the same time — are kept.
    static func removeNamespacesOfEndedProcesses(in suite: UserDefaults) {
        let domain = suite.persistentDomain(forName: isolatedSuiteName) ?? [:]
        for key in domain.keys {
            guard let owningProcessIdentifier = owningProcessIdentifier(ofKey: key),
                  !isProcessRunning(owningProcessIdentifier)
            else { continue }
            suite.removeObject(forKey: key)
        }
    }

    /// The process an isolated key was written by, read back from the
    /// prefix `makeIsolated()` gives it; `nil` for any other key.
    static func owningProcessIdentifier(ofKey key: String) -> pid_t? {
        let components = key.split(separator: "_", maxSplits: 3)
        guard components.count == 4, components[0] == isolatedKeyMarker else { return nil }
        return pid_t(components[1])
    }

    /// Whether a process with this identifier exists. `EPERM` means it does
    /// but belongs to someone else; either way it is not ours to sweep.
    private static func isProcessRunning(_ processIdentifier: pid_t) -> Bool {
        kill(processIdentifier, 0) == 0 || errno == EPERM
    }
}
