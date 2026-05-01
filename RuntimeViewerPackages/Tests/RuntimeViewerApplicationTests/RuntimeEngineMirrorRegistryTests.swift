import Testing
import Foundation
import OrderedCollections
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerApplication

@Suite("RuntimeEngineMirrorRegistry")
@MainActor
struct RuntimeEngineMirrorRegistryTests {

    // MARK: - Helpers

    private func descriptor(
        engineID: String,
        originChain: [String] = ["origin-host"],
        hostName: String = "TestHost",
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        iconData: Data? = nil
    ) -> RemoteEngineDescriptor {
        RemoteEngineDescriptor(
            engineID: engineID,
            source: .directTCP(name: engineID, host: host, port: port, role: .server),
            hostName: hostName,
            originChain: originChain,
            directTCPHost: host,
            directTCPPort: port,
            iconData: iconData
        )
    }

    private nonisolated func makeEngine(for descriptor: RemoteEngineDescriptor) -> RuntimeEngine {
        RuntimeEngine(
            source: .directTCP(
                name: descriptor.source.description,
                host: descriptor.directTCPHost,
                port: descriptor.directTCPPort,
                role: .client
            ),
            hostInfo: HostInfo(
                hostID: descriptor.originChain.first ?? "",
                hostName: descriptor.hostName
            ),
            originChain: descriptor.originChain
        )
    }

    // MARK: - Reconcile

    @Test("empty registry accepts all descriptors and records ownership")
    func emptyRegistryAcceptsAll() {
        let registry = RuntimeEngineMirrorRegistry()
        let descriptors = [
            descriptor(engineID: "host-A/e1"),
            descriptor(engineID: "host-A/e2"),
        ]

        let outcome = registry.reconcile(
            descriptors: descriptors,
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        guard case .applied(let removed, let added) = outcome else {
            Issue.record("expected .applied, got \(outcome)")
            return
        }
        #expect(removed.isEmpty)
        #expect(added.map(\.descriptor.engineID) == ["host-A/e1", "host-A/e2"])
        #expect(registry.engines.keys.elements == ["host-A/e1", "host-A/e2"])
        #expect(registry.ownership == ["host-A/e1": "host-A", "host-A/e2": "host-A"])
        #expect(registry.lastDescriptorIDsBySource["host-A"] == ["host-A/e1", "host-A/e2"])
    }

    @Test("identical re-push from same source is deduplicated")
    func identicalPushIsDedup() {
        let registry = RuntimeEngineMirrorRegistry()
        let descriptors = [descriptor(engineID: "host-A/e1")]

        _ = registry.reconcile(
            descriptors: descriptors,
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let second = registry.reconcile(
            descriptors: descriptors,
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        #expect(second == .skippedDuplicate)
        #expect(registry.engines.count == 1)
    }

    @Test("source A's update never wipes source B's mirrors")
    func crossSourceIsolation() {
        let registry = RuntimeEngineMirrorRegistry()

        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "host-A/e1"), descriptor(engineID: "host-A/e2")],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "host-B/e1")],
            fromHostID: "host-B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        // Now host-A drops one of its descriptors.
        let outcome = registry.reconcile(
            descriptors: [descriptor(engineID: "host-A/e1")],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        guard case .applied(let removed, let added) = outcome else {
            Issue.record("expected .applied")
            return
        }
        #expect(removed.map(\.engineID) == ["host-A/e2"])
        #expect(added.isEmpty)
        // Host-B's mirror must still be present.
        #expect(registry.engines["host-B/e1"] != nil)
        #expect(registry.ownership["host-B/e1"] == "host-B")
    }

    @Test("first source to report an engineID owns it; later duplicates ignored")
    func firstComeFirstServed() {
        let registry = RuntimeEngineMirrorRegistry()
        let shared = descriptor(engineID: "shared/e1")

        _ = registry.reconcile(
            descriptors: [shared],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let secondOutcome = registry.reconcile(
            descriptors: [shared],
            fromHostID: "host-B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        guard case .applied(let removed, let added) = secondOutcome else {
            Issue.record("expected .applied for new source")
            return
        }
        #expect(removed.isEmpty)
        // The duplicate engineID is silently skipped.
        #expect(added.isEmpty)
        // Host-A still owns it; host-B's dedup cache reflects what it tried to push.
        #expect(registry.ownership["shared/e1"] == "host-A")
        #expect(registry.lastDescriptorIDsBySource["host-B"] == ["shared/e1"])
    }

    @Test("descriptors whose originChain contains localInstanceID are filtered as cycles")
    func cycleDetectionFiltersDescriptor() {
        let registry = RuntimeEngineMirrorRegistry()
        let cyclic = descriptor(engineID: "cyclic", originChain: ["host-A", "local"])
        let normal = descriptor(engineID: "normal")

        let outcome = registry.reconcile(
            descriptors: [cyclic, normal],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        guard case .applied(_, let added) = outcome else {
            Issue.record("expected .applied")
            return
        }
        #expect(added.map(\.descriptor.engineID) == ["normal"])
        #expect(registry.engines.keys.contains("cyclic") == false)
    }

    // MARK: - Cleanup

    @Test("clearOwnMirror removes only the matching mirror entry")
    func clearOwnMirrorIsScoped() {
        let registry = RuntimeEngineMirrorRegistry()
        _ = registry.reconcile(
            descriptors: [
                descriptor(engineID: "e1"),
                descriptor(engineID: "e2"),
            ],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let target = registry.engines["e1"]!
        let removed = registry.clearOwnMirror(matching: target)

        #expect(removed.map(\.engineID) == ["e1"])
        #expect(registry.engines.keys.elements == ["e2"])
        #expect(registry.ownership == ["e2": "host-A"])
        // Dedup cache stays intact (only direct-peer disconnect should clear it).
        #expect(registry.lastDescriptorIDsBySource["host-A"] == ["e1", "e2"])
    }

    @Test("clearAllOwnedBy removes only the disconnected peer's mirrors and clears its dedup cache")
    func clearAllOwnedByIsScoped() {
        let registry = RuntimeEngineMirrorRegistry()

        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "host-A/e1"), descriptor(engineID: "host-A/e2")],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )
        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "host-B/e1")],
            fromHostID: "host-B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let removed = registry.clearAllOwnedBy(hostID: "host-A")

        #expect(Set(removed.map(\.engineID)) == ["host-A/e1", "host-A/e2"])
        #expect(registry.engines.keys.elements == ["host-B/e1"])
        #expect(registry.ownership == ["host-B/e1": "host-B"])
        #expect(registry.lastDescriptorIDsBySource["host-A"] == nil)
        #expect(registry.lastDescriptorIDsBySource["host-B"] == ["host-B/e1"])
    }

    @Test("clearAllOwnedBy keeps transitive mirrors that an unrelated peer reported")
    func clearAllOwnedByDoesNotTouchTransitiveOwnedByOthers() {
        // Topology: same engineID 'X/orphan' was reported by host-A first (so A owns it)
        // and then by host-B. Disconnecting host-B should NOT remove the mirror;
        // host-A still owns it.
        let registry = RuntimeEngineMirrorRegistry()
        let shared = descriptor(engineID: "X/orphan", originChain: ["X"])

        _ = registry.reconcile(
            descriptors: [shared],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )
        _ = registry.reconcile(
            descriptors: [shared],
            fromHostID: "host-B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        _ = registry.clearAllOwnedBy(hostID: "host-B")

        #expect(registry.engines["X/orphan"] != nil)
        #expect(registry.ownership["X/orphan"] == "host-A")
    }

    @Test("clearAllWithHostID removes everything namespaced under the host, regardless of ownership")
    func clearAllWithHostIDMatchesByEngineIDPrefix() {
        // Topology: leaf 'C' is reachable to us both directly (C pushes its own engines,
        // so ownership=C) and via intermediate 'B' (B forwards C's engines, so ownership=B,
        // but engineID still starts with 'C/'). Plus an unrelated host 'D' whose entries
        // must survive.
        let registry = RuntimeEngineMirrorRegistry()
        _ = registry.reconcile(
            descriptors: [
                descriptor(engineID: "C/e1", originChain: ["C"]),
                descriptor(engineID: "C/e2", originChain: ["C"]),
            ],
            fromHostID: "C",
            localInstanceID: "local",
            engineFactory: makeEngine
        )
        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "C/e3", originChain: ["C", "B"])],
            fromHostID: "B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )
        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "D/e1", originChain: ["D"])],
            fromHostID: "D",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let removed = registry.clearAllWithHostID(hostID: "C")

        #expect(Set(removed.map(\.engineID)) == ["C/e1", "C/e2", "C/e3"])
        #expect(registry.engines.keys.elements == ["D/e1"])
        #expect(registry.ownership == ["D/e1": "D"])
        // Dedup caches are untouched — clearAllWithHostID is keyed on the leaf's hostID,
        // which is unrelated to which forwarder's cache should be invalidated.
        #expect(registry.lastDescriptorIDsBySource["C"] == ["C/e1", "C/e2"])
        #expect(registry.lastDescriptorIDsBySource["B"] == ["C/e3"])
        #expect(registry.lastDescriptorIDsBySource["D"] == ["D/e1"])
    }

    @Test("clearAllWithHostID returns empty when no engineID is namespaced under the host")
    func clearAllWithHostIDIsEmptyWhenNoMatch() {
        let registry = RuntimeEngineMirrorRegistry()
        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "host-A/e1", originChain: ["host-A"])],
            fromHostID: "host-A",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        #expect(registry.clearAllWithHostID(hostID: "missing-host").isEmpty)
        #expect(registry.engines.keys.elements == ["host-A/e1"])
    }

    @Test("leaf disconnect via union(clearAllOwnedBy, clearAllWithHostID) drops both routes")
    func leafDisconnectDropsForwardedMirrors() {
        // Mirrors the manager-side cleanup: a leaf peer C disconnects. Entries can be
        // either directly owned by C or forwarded through some other peer; both groups
        // must go away in a single disconnect handler. clearAllOwnedBy alone would miss
        // the forwarded mirror; clearAllWithHostID alone would miss the dedup-cache
        // invalidation. The union covers both.
        let registry = RuntimeEngineMirrorRegistry()
        // C's own engine, forwarded directly by C.
        _ = registry.reconcile(
            descriptors: [descriptor(engineID: "C/local", originChain: ["C"])],
            fromHostID: "C",
            localInstanceID: "local",
            engineFactory: makeEngine
        )
        // B forwards C's other engine alongside its own — must arrive in a single
        // reconcile, otherwise B's second push without C/forwarded would clear it.
        _ = registry.reconcile(
            descriptors: [
                descriptor(engineID: "C/forwarded", originChain: ["C", "B"]),
                descriptor(engineID: "B/local", originChain: ["B"]),
            ],
            fromHostID: "B",
            localInstanceID: "local",
            engineFactory: makeEngine
        )

        let peer = registry.clearAllOwnedBy(hostID: "C")
        let origin = registry.clearAllWithHostID(hostID: "C")
        let all = peer + origin

        #expect(Set(all.map(\.engineID)) == ["C/local", "C/forwarded"])
        #expect(registry.engines.keys.elements == ["B/local"])
        #expect(registry.ownership == ["B/local": "B"])
        // C's dedup cache went away with clearAllOwnedBy; B's stays.
        #expect(registry.lastDescriptorIDsBySource["C"] == nil)
        #expect(registry.lastDescriptorIDsBySource["B"] == ["C/forwarded", "B/local"])
    }

    // MARK: - Concurrency

    /// Race-condition regression test. The crash that motivated this refactor came from
    /// `handleEngineListChanged` running on the cooperative pool while the main actor
    /// also wrote into the same dictionaries. Now that all mutation goes through this
    /// `@MainActor` registry, the same workload — many tasks concurrently calling
    /// `reconcile` and `clearAllOwnedBy` — must serialize cleanly and leave the
    /// state self-consistent (no orphan ownership, no duplicate engines, no crash).
    ///
    /// Run this test under TSan to catch any latent unsafe access.
    @Test("concurrent reconcile + cleanup keeps internal state consistent")
    func concurrentReconcileIsConsistent() async {
        let registry = RuntimeEngineMirrorRegistry()
        let sources = (0..<8).map { "host-\($0)" }
        let descriptorsPerSource = 16

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                let descriptors = (0..<descriptorsPerSource).map { idx in
                    descriptor(
                        engineID: "\(source)/e\(idx)",
                        originChain: [source]
                    )
                }
                // Push the full set, then drop half, then push full again — all on
                // independent detached tasks that race for the main actor.
                for variant in 0..<3 {
                    let payload: [RemoteEngineDescriptor] = {
                        switch variant {
                        case 0: return descriptors
                        case 1: return Array(descriptors.prefix(descriptorsPerSource / 2))
                        default: return descriptors
                        }
                    }()
                    group.addTask {
                        await Task.detached { @MainActor in
                            _ = registry.reconcile(
                                descriptors: payload,
                                fromHostID: source,
                                localInstanceID: "local",
                                engineFactory: { descriptor in
                                    RuntimeEngine(
                                        source: .directTCP(
                                            name: descriptor.source.description,
                                            host: descriptor.directTCPHost,
                                            port: descriptor.directTCPPort,
                                            role: .client
                                        ),
                                        hostInfo: HostInfo(
                                            hostID: descriptor.originChain.first ?? "",
                                            hostName: descriptor.hostName
                                        ),
                                        originChain: descriptor.originChain
                                    )
                                }
                            )
                        }.value
                    }
                }
                // Also race a peer-disconnect cleanup against the reconciles.
                group.addTask {
                    await Task.detached { @MainActor in
                        _ = registry.clearAllOwnedBy(hostID: source)
                    }.value
                }
            }
        }

        // Internal invariants — independent of which task happened to win each race.
        // Every owned engine must exist in `engines`, and vice versa.
        for (engineID, _) in registry.ownership {
            #expect(registry.engines[engineID] != nil, "ownership references missing engine \(engineID)")
        }
        for (engineID, _) in registry.engines {
            #expect(registry.ownership[engineID] != nil, "engine \(engineID) is present without ownership")
        }
        // No engineID can appear under two owners (impossible by construction, but
        // verifies the invariant holds after the race).
        let ownerCounts = Dictionary(grouping: registry.ownership.keys, by: { $0 }).mapValues(\.count)
        #expect(ownerCounts.values.allSatisfy { $0 == 1 })
    }
}
