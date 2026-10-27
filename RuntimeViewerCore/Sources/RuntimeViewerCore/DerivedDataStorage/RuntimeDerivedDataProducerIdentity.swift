import Foundation
import MachOKit

/// The code that produced a piece of derived data. Data produced by other
/// code — another build of the app, or this build's code after it was
/// rebuilt — is never read, so a change to how a corpus is printed cannot
/// show the output of the old code.
///
/// A SHA-256 digest over the in-memory `LC_UUID` of the image that holds
/// RuntimeViewerCore's code and of every image it depends on, directly or
/// not, that is loaded and outside the shared cache, each with its name.
/// Read from the loaded headers, never from disk: an app rebuilt in place
/// while its service runs leaves the service with the identity of the code
/// it is running. Images loaded later through Load Frameworks… are not
/// dependencies and do not count.
///
/// The names are install names, or the file name of an image that has none,
/// never the whole path: the system may run an app it quarantined from a
/// new random location at every launch (App Translocation), and the code is
/// the same wherever it lies.
public struct RuntimeDerivedDataProducerIdentity: Hashable, Sendable {
    /// Lowercase hexadecimal, all 64 digits.
    public let digest: String

    public init(digest: String) {
        self.digest = digest
    }

    /// The first sixteen digits: the name of the producer's directory.
    public var directoryName: String {
        String(digest.prefix(16))
    }

    /// `nil` when the image holding RuntimeViewerCore cannot be read, or an
    /// image that counts carries no `LC_UUID`.
    public static func currentProcess() -> RuntimeDerivedDataProducerIdentity? {
        #if canImport(Darwin)
        // `#dsohandle` here is the header of the image this file is linked
        // into: the service's executable when Core is linked statically, the
        // Mac Catalyst plug-in, or a framework of its own.
        guard let images = codeImages(rootedAt: UnsafeRawPointer(#dsohandle)) else { return nil }
        return RuntimeDerivedDataProducerIdentity(digest: digest(of: images))
        #else
        return nil
        #endif
    }

    /// The digest of an explicit list of images, in any order.
    static func digest(of images: [(name: String, uuid: UUID)]) -> String {
        let lines = images.map { "\($0.name)\t\($0.uuid.uuidString)" }.sorted()
        return RuntimeDerivedDataDigest.hexadecimalDigest(of: Data(lines.joined(separator: "\n").utf8))
    }

    #if canImport(Darwin)
    /// The image at `rootHeader` and the images outside the shared cache it
    /// loads, directly or through one another, each named and identified.
    private static func codeImages(rootedAt rootHeader: UnsafeRawPointer) -> [(name: String, uuid: UUID)]? {
        struct LoadedImage {
            let image: MachOImage
            let name: String
        }
        var loadedImagesByHeader: [UnsafeRawPointer: LoadedImage] = [:]
        var loadedImageHeadersByInstallName: [String: UnsafeRawPointer] = [:]
        for index in 0 ..< _dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            let image = MachOImage(ptr: header)
            guard !image.header.isInDyldCache else { continue }
            let installName = image.path
            let fileName = _dyld_get_image_name(index).map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent }
            guard let name = installName ?? fileName else { continue }
            let headerPointer = UnsafeRawPointer(header)
            loadedImagesByHeader[headerPointer] = LoadedImage(image: image, name: name)
            if let installName {
                loadedImageHeadersByInstallName[installName] = headerPointer
            }
        }

        guard loadedImagesByHeader[rootHeader] != nil else { return nil }
        var identities: [(name: String, uuid: UUID)] = []
        var visitedHeaders: Set<UnsafeRawPointer> = [rootHeader]
        var pendingHeaders = [rootHeader]
        while let header = pendingHeaders.popLast() {
            guard let loadedImage = loadedImagesByHeader[header],
                  let uuid = loadedImage.image.loadCommands.info(of: LoadCommand.uuid)?.uuid
            else { return nil }
            identities.append((loadedImage.name, uuid))
            // A dependency is named by the install name it had when the image
            // was linked, which is the `LC_ID_DYLIB` of the image dyld loaded
            // for it. One in the shared cache has no entry here.
            for dependency in loadedImage.image.dependencies {
                guard let dependencyHeader = loadedImageHeadersByInstallName[dependency.dylib.name],
                      visitedHeaders.insert(dependencyHeader).inserted
                else { continue }
                pendingHeaders.append(dependencyHeader)
            }
        }
        return identities
    }
    #endif
}
