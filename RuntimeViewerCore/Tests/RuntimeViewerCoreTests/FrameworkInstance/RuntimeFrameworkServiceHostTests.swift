#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerCommunication

/// Frameworks loaded into an instance of their own, with both processes
/// played by this one: a `RuntimeFrameworkServiceHost` over an anonymous
/// listener stands in for an instance of the framework service, and a
/// `.frameworkInstance` engine connected through an endpoint carrying the
/// instance's launch payload stands in for the app's.
///
/// Other suites load images into this process while these run, so the lists
/// are checked for this test's own frameworks, never for being empty.
@Suite("RuntimeFrameworkServiceHost", .serialized)
struct RuntimeFrameworkServiceHostTests {
    private static let appRpaths = ["@executable_path/../Frameworks", "@loader_path/Frameworks"]

    private static func makeHost() throws -> (host: RuntimeFrameworkServiceHost, endpoint: RuntimeXPCServiceEndpoint) {
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeFrameworkServiceHost(connection: listener)
        host.activate()
        return (host, endpoint)
    }

    private static func connectedClient(for instance: RuntimeFrameworkInstance, at endpoint: RuntimeXPCServiceEndpoint) async throws -> RuntimeEngine {
        let client = RuntimeEngine(source: instance.source, engineID: "framework-service-test.\(instance.identifier)")
        let payload = try RuntimeFrameworkService.launchPayload(for: instance)
        try await client.connect(credential: .xpcService(.anonymousListener(endpoint.carryingLaunchPayload(payload))))
        return client
    }

    private static func instance(named name: String) -> RuntimeFrameworkInstance {
        RuntimeFrameworkInstance(name: name, frameworkURL: URL(fileURLWithPath: "/A/\(name).framework"))
    }

    /// The paths a root node's leaves name.
    private static func leafPaths(under rootName: String, in nodes: [RuntimeImageNode]) -> [String] {
        guard let root = nodes.first(where: { $0.name == rootName }) else { return [] }
        func leaves(_ node: RuntimeImageNode) -> [String] {
            node.isLeaf ? [node.path] : node.children.flatMap(leaves)
        }
        return root.children.flatMap(leaves)
    }

    private static func listed(_ path: String) -> String {
        DyldUtilities.pathAsDyldListsIt(path)
    }

    @Test("A launch payload round-trips the instance it names")
    func launchPayloadRoundTrips() throws {
        let instance = Self.instance(named: "Foo")

        let decoded = try RuntimeFrameworkService.instance(fromLaunchPayload: RuntimeFrameworkService.launchPayload(for: instance))

        #expect(decoded == instance)
    }

    @Test("An engine of a framework instance forwards from the moment it exists")
    func engineForAFrameworkInstanceForwardsFromTheStart() async {
        let engine = RuntimeEngine(source: Self.instance(named: "Unconnected").source, engineID: "framework-service-test.unconnected")

        #expect(await engine.forwardsRequests)
        #expect(engine.diagnosesImageLoadsOnRequest)
    }

    @Test("A loaded framework is listed under Frameworks, and what it brings in from outside the shared cache under Dependencies")
    func hostListsLoadedFrameworksAndTheirNonCacheDependencies() async throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: ["@loader_path/../../.."]),
        ])
        let foo = application.framework("Foo")
        let bar = application.framework("Bar")
        let (host, endpoint) = try Self.makeHost()
        let client = try await Self.connectedClient(for: Self.instance(named: "Foo"), at: endpoint)
        defer { Task { await client.stop(); await host.stop() } }
        let serviceEngine = try #require(host.engine)

        #expect(!Self.leafPaths(under: "Frameworks", in: serviceEngine.imageNodes).contains(Self.listed(foo.binaryPath)))

        try await client.loadImageInServingProcess(at: foo.binaryPath)

        let frameworks = Self.leafPaths(under: "Frameworks", in: serviceEngine.imageNodes)
        let dependencies = Self.leafPaths(under: "Dependencies", in: serviceEngine.imageNodes)
        #expect(frameworks.contains(Self.listed(foo.binaryPath)))
        #expect(dependencies.contains(Self.listed(bar.binaryPath)))
        #expect(!frameworks.contains(Self.listed(bar.binaryPath)))
        #expect(!(frameworks + dependencies).contains { DyldUtilities.isInDyldSharedCache($0) })
        let imageList = await serviceEngine.imageList
        #expect(imageList.contains(Self.listed(foo.binaryPath)))
        #expect(imageList.contains(Self.listed(bar.binaryPath)))
        let received = await pollUntil {
            Self.leafPaths(under: "Frameworks", in: client.imageNodes).contains(Self.listed(foo.binaryPath))
        }
        #expect(received, "the app's engine did not receive the rebuilt nodes")
    }

    @Test("A framework dyld refused is listed under Frameworks as not loaded, and fails with its diagnosis")
    func failedFrameworkIsListedUnderFrameworks() async throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Bar"),
            .init(baseName: "Foo", dependencies: ["Bar"], rpaths: Self.appRpaths),
        ])
        let foo = application.framework("Foo")
        let (host, endpoint) = try Self.makeHost()
        let client = try await Self.connectedClient(for: Self.instance(named: "Foo"), at: endpoint)
        defer { Task { await client.stop(); await host.stop() } }
        let serviceEngine = try #require(host.engine)

        let error = await #expect(throws: RuntimeImageLoadError.self) {
            try await client.loadImageInServingProcess(at: foo.binaryPath)
        }

        #expect(error?.diagnosis?.remedy?.hostApplicationPath == application.applicationPath)
        #expect(Self.leafPaths(under: "Frameworks", in: serviceEngine.imageNodes).contains(Self.listed(foo.binaryPath)))
        #expect(!(await serviceEngine.imageList).contains(Self.listed(foo.binaryPath)))
    }

    @Test("An image loaded before the instance started is not listed")
    func imagesLoadedBeforeTheInstanceStartedAreNotListed() async throws {
        let application = try ImageLoadFixtures.makeHostApplication(frameworks: [
            .init(baseName: "Early"),
        ])
        let early = application.framework("Early")
        try DyldUtilities.loadImage(at: early.binaryPath)
        let (host, endpoint) = try Self.makeHost()
        let client = try await Self.connectedClient(for: Self.instance(named: "Early"), at: endpoint)
        defer { Task { await client.stop(); await host.stop() } }
        let serviceEngine = try #require(host.engine)

        let listedPaths = Self.leafPaths(under: "Frameworks", in: serviceEngine.imageNodes)
            + Self.leafPaths(under: "Dependencies", in: serviceEngine.imageNodes)

        #expect(!listedPaths.contains(Self.listed(early.binaryPath)))
        #expect(!(await serviceEngine.imageList).contains(Self.listed(early.binaryPath)))
    }

    @Test("The process catalog still does not rebuild its nodes after a load")
    func processCatalogStillDoesNotRebuildNodes() {
        #expect(!RuntimeProcessImageCatalog().rootNodesFollowLoads)
        #expect(RuntimeFrameworkInstanceImageCatalog(baselineImagePaths: []).rootNodesFollowLoads)
    }
}

/// The source of a framework instance, and the scope its bookmarks are kept
/// under.
@Suite("Framework instance source")
struct RuntimeFrameworkInstanceSourceTests {
    @Test("Two framework instances are the same source exactly when their identifiers are")
    func frameworkInstanceSourcesAreEqualByIdentifierAlone() {
        let first = RuntimeSource.frameworkInstance(name: "Foo.framework (Isolated)", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: "one")
        let renamed = RuntimeSource.frameworkInstance(name: "Other", frameworkURL: URL(fileURLWithPath: "/B/Bar.framework"), identifier: "one")
        let second = RuntimeSource.frameworkInstance(name: "Foo.framework (Isolated)", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: "two")

        #expect(first == renamed)
        #expect(first.hashValue == renamed.hashValue)
        #expect(first != second)
        #expect(first != .local)
        #expect(first.description == "Foo.framework (Isolated)")
        #expect(first.identifier == "frameworkInstance.one")
    }

    @Test("A framework instance has no role, is not mirrored to peers and is no XPC Mach service")
    func frameworkInstanceIsNotMirrorableToPeers() {
        let source = RuntimeSource.frameworkInstance(name: "Foo", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: "one")

        #expect(source.remoteRole == nil)
        #expect(!source.isMirrorableToPeers)
        #expect(!source.isXPC)
    }

    @Test("A framework instance's bookmarks are filed under its first framework, and the key reads back")
    func bookmarkScopeOfAFrameworkInstanceRoundTripsThroughItsRawValue() throws {
        let source = RuntimeSource.frameworkInstance(name: "Foo", frameworkURL: URL(fileURLWithPath: "/A/./Foo.framework"), identifier: "one")
        let anotherInstance = RuntimeSource.frameworkInstance(name: "Foo", frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), identifier: "two")

        let scope = try #require(RuntimeBookmarkScope.recovered(from: source))

        #expect(scope == .identified(.frameworkInstance(path: "/A/Foo.framework")))
        #expect(RuntimeBookmarkScope.recovered(from: anotherInstance) == scope)
        let identity = RuntimeBookmarkScope.Identity.frameworkInstance(path: "/A/Foo.framework")
        #expect(RuntimeBookmarkScope.Identity(rawValue: identity.rawValue) == identity)
        #expect(identity.kind == .frameworkInstance)
        #expect(identity.role == nil)
    }
}

private func pollUntil(
    timeout: Duration = .seconds(30),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

#endif
