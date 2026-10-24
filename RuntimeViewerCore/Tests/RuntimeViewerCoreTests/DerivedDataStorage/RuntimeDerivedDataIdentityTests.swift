import Foundation
import Testing
@testable import RuntimeViewerCore

/// What decides whether stored data is this system's and this code's: the
/// system identity, the producer identity, the location, and the Transformer
/// digest in a corpus's name.
@Suite("Derived data identities")
struct RuntimeDerivedDataIdentityTests {
    // MARK: - System

    @Test("A system directory name gives its build back")
    func systemDirectoryNameRoundTrip() {
        let system = DerivedDataTestIdentities.system
        #expect(system.directoryName == "macOS-27.2-26B5112a-6C1A8B6E-3D3F-4C47-9A1F-6E2B7B0D9C11")
        #expect(RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: system.directoryName) == "26B5112a")
    }

    @Test("A name not made by a system identity has no build", arguments: [
        "macOS-27.2-26B5112a",
        "iOS-27.2-26B5112a-6C1A8B6E-3D3F-4C47-9A1F-6E2B7B0D9C11",
        "macOS-27.2-26B5112a-not-a-uuid-at-all-here",
        "macOS-27.2--6C1A8B6E-3D3F-4C47-9A1F-6E2B7B0D9C11",
        ".DS_Store",
    ])
    func foreignDirectoryNames(name: String) {
        #expect(RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: name) == nil)
    }

    @Test("A version or build with a hyphen still makes a name that splits back")
    func hyphenatedParts() {
        let system = RuntimeDerivedDataSystemIdentity(platform: .macCatalyst, operatingSystemVersion: "27.2-beta", operatingSystemBuild: "26B-5112", sharedCacheUUID: DerivedDataTestIdentities.sharedCacheUUID)
        #expect(system.directoryName.hasPrefix("macCatalyst-27.2_beta-26B_5112-"))
        #expect(RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: system.directoryName) == "26B_5112")
    }

    @Test("This process's system is the running one")
    func currentSystem() throws {
        let system = try #require(RuntimeDerivedDataSystemIdentity.current())
        #expect(system.platform == .macOS)
        #expect(!system.operatingSystemBuild.isEmpty)
        #expect(system.sharedCacheUUID == RuntimeDerivedDataSystemIdentity.current()?.sharedCacheUUID)
    }

    // MARK: - Producer

    private static let serviceImage = (name: "RuntimeViewerLocalRuntimeService", uuid: UUID(uuidString: "0B7E3E2A-5C1D-4E8F-8A21-3F0C5D9E7B44")!)
    private static let dependencyImage = (name: "@rpath/libswiftCompatibilitySpan.dylib", uuid: UUID(uuidString: "5D2C1B0A-9E8F-4D7C-8B6A-1F2E3D4C5B6A")!)

    @Test("The producer digest is stable and does not depend on the order of the images")
    func producerDigestIsStable() {
        let digest = RuntimeDerivedDataProducerIdentity.digest(of: [Self.serviceImage, Self.dependencyImage])
        #expect(digest.count == 64)
        #expect(digest == RuntimeDerivedDataProducerIdentity.digest(of: [Self.serviceImage, Self.dependencyImage]))
        #expect(digest == RuntimeDerivedDataProducerIdentity.digest(of: [Self.dependencyImage, Self.serviceImage]))
    }

    @Test("Another UUID for any image is another producer")
    func producerDigestFollowsEveryUUID() {
        let digest = RuntimeDerivedDataProducerIdentity.digest(of: [Self.serviceImage, Self.dependencyImage])
        let rebuiltService = (name: Self.serviceImage.name, uuid: UUID())
        let rebuiltDependency = (name: Self.dependencyImage.name, uuid: UUID())
        #expect(digest != RuntimeDerivedDataProducerIdentity.digest(of: [rebuiltService, Self.dependencyImage]))
        #expect(digest != RuntimeDerivedDataProducerIdentity.digest(of: [Self.serviceImage, rebuiltDependency]))
        #expect(digest != RuntimeDerivedDataProducerIdentity.digest(of: [Self.serviceImage]))
    }

    @Test("This process's code has a producer identity")
    func currentProducer() throws {
        let producer = try #require(RuntimeDerivedDataProducerIdentity.currentProcess())
        #expect(producer.digest.count == 64)
        #expect(producer.directoryName.count == 16)
        #expect(producer == RuntimeDerivedDataProducerIdentity.currentProcess())
    }

    // MARK: - Location

    private static func makeApplication(at applicationURL: URL, info: [String: String]) throws {
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL.appendingPathComponent("XPCServices/RuntimeViewerLocalRuntimeService.xpc", isDirectory: true), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    @Test("The application and the service it embeds come to the same location")
    func locationOfApplicationAndService() throws {
        let directory = try DerivedDataTestDirectory()
        let applicationURL = directory.url.appendingPathComponent("RuntimeViewer.app", isDirectory: true)
        try Self.makeApplication(at: applicationURL, info: [
            "CFBundleIdentifier": "dev.JH.RuntimeViewer.arm64e",
            LocalRuntimeService.bundleIdentifierInfoDictionaryKey: "dev.JH.RuntimeViewer.arm64e.LocalRuntimeService",
        ])
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)

        let fromApplication = try #require(RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: applicationURL, cachesDirectoryURL: cachesURL))
        let fromService = try #require(RuntimeDerivedDataLocation.enclosingApplication(
            ofBundleAt: applicationURL.appendingPathComponent("Contents/XPCServices/RuntimeViewerLocalRuntimeService.xpc", isDirectory: true),
            cachesDirectoryURL: cachesURL
        ))
        #expect(fromApplication == fromService)
        #expect(fromApplication.rootURL.path == cachesURL.appendingPathComponent("dev.JH.RuntimeViewer.arm64e/DerivedData").path)
        #expect(fromApplication.applicationURL.path == applicationURL.path)
    }

    @Test("An application whose Info.plist names no local-runtime service has no location")
    func applicationWithoutService() throws {
        let directory = try DerivedDataTestDirectory()
        let applicationURL = directory.url.appendingPathComponent("Other.app", isDirectory: true)
        try Self.makeApplication(at: applicationURL, info: ["CFBundleIdentifier": "com.example.Other"])
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)
        #expect(RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: applicationURL, cachesDirectoryURL: cachesURL) == nil)
        #expect(RuntimeDerivedDataLocation.enclosingApplication(
            ofBundleAt: applicationURL.appendingPathComponent("Contents/XPCServices/RuntimeViewerLocalRuntimeService.xpc", isDirectory: true),
            cachesDirectoryURL: cachesURL
        ) == nil)
    }

    @Test("A bundle outside any application has no location")
    func bundleOutsideApplication() throws {
        let directory = try DerivedDataTestDirectory()
        let cachesURL = directory.url.appendingPathComponent("Caches", isDirectory: true)
        #expect(RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: directory.url.appendingPathComponent("runtime-viewer-cli"), cachesDirectoryURL: cachesURL) == nil)
        #expect(RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: directory.url.appendingPathComponent("Tests.xctest", isDirectory: true), cachesDirectoryURL: cachesURL) == nil)
        // The test process itself is no RuntimeViewer application.
        #expect(RuntimeDerivedDataLocation.enclosingApplication(of: .main) == nil)
    }

    // MARK: - Enabling

    @Test("A process that never turned derived data on gives its engines no store")
    func disabledByDefault() {
        #expect(!RuntimeDerivedData.isEnabledInThisProcess)
        #expect(RuntimeEngine.processDerivedDataStore == nil)
    }

    // MARK: - Transformer digest

    /// The C type replacements of the user's Release settings, in the order
    /// that file stores them.
    private static let releaseCTypeJSON = #"{"isEnabled": true, "replacements": ["long", "NSInteger", "ushort", "uint16_t", "uchar", "uint8_t", "ulong", "NSUInteger", "uint", "uint32_t", "char", "int8_t", "longLong", "NSInteger", "double", "CGFloat", "int", "int32_t", "ulongLong", "NSUInteger", "short", "int16_t"]}"#

    /// The same eleven replacements as the user's Debug settings store them.
    private static let debugCTypeJSON = #"{"replacements": ["uint", "uint32_t", "ulongLong", "NSUInteger", "ulong", "NSUInteger", "int", "int32_t", "uchar", "uint8_t", "long", "NSInteger", "longLong", "NSInteger", "ushort", "uint16_t", "double", "CGFloat", "char", "int8_t", "short", "int16_t"], "isEnabled": true}"#

    private static func configuration(cTypeJSON: String, enumLayoutTemplate: String = "${strategy}") throws -> Transformer.Configuration {
        let json = #"{"objc": {"cType": \#(cTypeJSON), "ivarOffset": {"isEnabled": false, "useHexadecimal": true, "template": "offset: ${offset}"}}, "swift": {"swiftEnumLayout": {"isEnabled": false, "template": "\#(enumLayoutTemplate)"}}}"#
        return try JSONDecoder().decode(Transformer.Configuration.self, from: Data(json.utf8))
    }

    @Test("Settings stored in different orders give one digest")
    func transformerDigestIgnoresStorageOrder() throws {
        let release = try Self.configuration(cTypeJSON: Self.releaseCTypeJSON)
        let debug = try Self.configuration(cTypeJSON: Self.debugCTypeJSON)
        #expect(release == debug)
        #expect(release.derivedDataDigest == debug.derivedDataDigest)
        #expect(release.derivedDataDigest.count == 16)
    }

    @Test("Equal configurations give one digest however their dictionaries were filled")
    func transformerDigestIgnoresInsertionOrder() {
        var forward = Transformer.Configuration()
        var backward = Transformer.Configuration()
        let patterns = Transformer.CType.Pattern.allCases
        for pattern in patterns {
            forward.objc.cType.replacements[pattern] = "Type\(pattern.rawValue)"
        }
        for pattern in patterns.reversed() {
            backward.objc.cType.replacements[pattern] = "Type\(pattern.rawValue)"
        }
        #expect(forward.derivedDataDigest == backward.derivedDataDigest)
    }

    @Test("Any other setting is another digest")
    func transformerDigestFollowsTheSettings() throws {
        let release = try Self.configuration(cTypeJSON: Self.releaseCTypeJSON)
        var otherReplacement = release
        otherReplacement.objc.cType.replacements[.double] = "double"
        var disabled = release
        disabled.objc.cType.isEnabled = false
        let otherTemplate = try Self.configuration(cTypeJSON: Self.releaseCTypeJSON, enumLayoutTemplate: "${summary}")
        let digests = [release, otherReplacement, disabled, otherTemplate, .default].map(\.derivedDataDigest)
        #expect(Set(digests).count == digests.count)
    }
}
