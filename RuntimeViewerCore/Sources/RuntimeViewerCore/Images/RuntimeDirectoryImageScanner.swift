import Foundation
import MachOKit

/// The Mach-O images in a directory and in everything below it — a bundle's
/// or a folder's — found from file headers alone.
///
/// Offline mode lists every image of a bundle or a folder it opens and opens
/// none of them until one is needed, so listing reads no more than a file's
/// header:
///
/// - Symbolic links are skipped: a framework's `Versions/Current` lists
///   nothing twice, and no link leads the walk out of the directory.
/// - Package contents and hidden directories are walked like any other — a
///   Swift package's `.build` holds its products.
/// - A file smaller than a page is skipped unread: a linked image holds at
///   least one whole page of `__TEXT`.
/// - Of the rest, only the images dyld loads are kept: executables, dynamic
///   libraries and bundles. An object file (`MH_OBJECT`) holds pointers no
///   linker has relocated yet, and the DWARF file of a dSYM (`MH_DSYM`) holds
///   no code, so neither can be read for its classes.
/// - A directory the walk cannot read is left out rather than ending it.
///
/// A fat file is judged by the slice this Mac prefers, the slice offline mode
/// reads it through.
enum RuntimeDirectoryImageScanner {
    /// One image: where it is, and what kind of image its header says it is.
    struct Image: Sendable, Hashable {
        let path: String
        let fileType: FileType
    }

    /// Every image under `directoryURL`, by path — a path that starts with
    /// `directoryURL.path`.
    ///
    /// The headers are read concurrently: the walk itself is cheap, and most
    /// of the time goes to opening files.
    static func images(in directoryURL: URL) -> [Image] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }
        var candidateURLs: [URL] = []
        for case let fileURL as URL in enumerator where isCandidate(fileURL) {
            candidateURLs.append(fileURL)
        }
        let rebasing = PathRebasing(directoryPath: directoryURL.path)
        var imagesByCandidateIndex = [Image?](repeating: nil, count: candidateURLs.count)
        imagesByCandidateIndex.withUnsafeMutableBufferPointer { imagesByCandidateIndex in
            DispatchQueue.concurrentPerform(iterations: candidateURLs.count) { index in
                guard let image = image(at: candidateURLs[index])?.image else { return }
                imagesByCandidateIndex[index] = Image(path: rebasing.rebased(image.path), fileType: image.fileType)
            }
        }
        return imagesByCandidateIndex.compactMap { $0 }.sorted { $0.path < $1.path }
    }

    /// The enumerator names what it finds under the directory's real path —
    /// `/private/var/…` for a directory at `/var/…` — but `RuntimeOfflineFile`
    /// names a directory by the path `resolvingSymlinksInPath()` gives, which
    /// leaves `/private` out, and a bundle's main executable is looked up by
    /// that path. Images are keyed under the latter.
    private struct PathRebasing {
        let directoryPath: String
        let realDirectoryPath: String

        init(directoryPath: String) {
            self.directoryPath = directoryPath
            if let resolvedPath = realpath(directoryPath, nil) {
                self.realDirectoryPath = String(cString: resolvedPath)
                free(resolvedPath)
            } else {
                self.realDirectoryPath = directoryPath
            }
        }

        func rebased(_ path: String) -> String {
            guard realDirectoryPath != directoryPath, path.hasPrefix(realDirectoryPath + "/") else { return path }
            return directoryPath + path.dropFirst(realDirectoryPath.count)
        }
    }

    /// The first image a breadth-first walk of `directoryURL` meets, taking
    /// the entries of each directory by name, together with the image opened:
    /// what offline mode tells a folder's platform by. The walk stops there.
    static func firstImage(in directoryURL: URL) -> (image: Image, machOFile: MachOFile)? {
        var pendingDirectoryURLs: [URL] = [directoryURL]
        var nextDirectoryIndex = 0
        while nextDirectoryIndex < pendingDirectoryURLs.count {
            let currentDirectoryURL = pendingDirectoryURLs[nextDirectoryIndex]
            nextDirectoryIndex += 1
            guard let entryURLs = try? FileManager.default.contentsOfDirectory(
                at: currentDirectoryURL,
                includingPropertiesForKeys: resourceKeys + [.isDirectoryKey],
                options: []
            ) else { continue }
            for entryURL in entryURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let values = try? entryURL.resourceValues(forKeys: Set(resourceKeys + [.isDirectoryKey])),
                      values.isSymbolicLink != true
                else { continue }
                if values.isDirectory == true {
                    pendingDirectoryURLs.append(entryURL)
                } else if isCandidate(entryURL), let found = image(at: entryURL) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Reading a File

    /// What a file must say of itself, before it is opened, to be read.
    private static let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

    /// The size of a page on the platforms with the smallest, x86_64's: no
    /// linked image is smaller.
    private static let smallestImageSize = 4096

    /// The kinds of image dyld loads.
    private static let loadableFileTypes: Set<FileType> = [.execute, .dylib, .bundle]

    private static func isCandidate(_ fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) >= smallestImageSize
    }

    /// The image at `fileURL` and the file opened, or `nil` when it is no
    /// image dyld loads. The magic is read first, so that a file that is no
    /// Mach-O is never mapped.
    private static func image(at fileURL: URL) -> (image: Image, machOFile: MachOFile)? {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        let leadingBytes = Array((try? fileHandle.read(upToCount: 8)) ?? Data())
        try? fileHandle.close()
        guard RuntimeOfflineFile.isMachOOrFatMagic(leadingBytes),
              let machOFile = try? RuntimeOfflineFile.machOFile(at: fileURL, preferring: nil),
              let fileType = machOFile.header.fileType,
              loadableFileTypes.contains(fileType)
        else { return nil }
        return (Image(path: fileURL.path, fileType: fileType), machOFile)
    }
}
