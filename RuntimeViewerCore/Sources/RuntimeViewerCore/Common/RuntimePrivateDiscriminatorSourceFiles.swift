import Foundation
import CryptoKit

/// The source files that private discriminators were derived from, recovered by hashing candidate
/// file names.
///
/// A discriminator is the MD5 of a module's name followed by a source file's name (see
/// `RuntimePrivateDeclaration`), so it cannot be decoded — but a file name can be guessed and
/// checked, and a 128-bit digest that matches is a certain identification: a recovered name is
/// never a guess, and the candidates only decide how many are found. They are tried in rising
/// order of cost, and the search stops once every discriminator asked for is found:
///
/// 1. `knownFileNames`, the Swift file names of public repositories whose code ships in Apple's
///    frameworks — OpenSwiftUI's reconstruction of SwiftUI among them.
/// 2. Every identifier in the image's names, as it is, without its leading underscores, and every
///    run of its camel-case words: `DefaultLayoutViewResponder` yields `Default`, `LayoutView`,
///    `ViewResponder`, … — each with `.swift` appended.
/// 3. `Type+Category.swift` from the words of the names declared with the same discriminator, which
///    usually carry both: `DateTextStorage` is declared in `Text+Date.swift`.
/// 4. The runs of step 2 followed by a word that often ends a file name (`Additions`, `Utils`, …),
///    or by a plural `s`.
/// 5. `Type+Category.swift` with any type name of the image before a word of step 3:
///    `ObjectLocation` is declared in `Binding+ObjectLocation.swift`.
///
/// On macOS 26.7 this recovers 408 of SwiftUICore's 439 discriminators, 576 of SwiftUI's 709 and
/// 84 of Foundation's 86 — without the known file names, 382, 561 and 64.
public struct RuntimePrivateDiscriminatorSourceFiles: Sendable {
    public struct SourceFile: Hashable, Sendable {
        /// The file's name, `Enabled.swift`.
        public let fileName: String

        /// The module name that went into the digest: a framework's own name (`SwiftUICore`), which
        /// is not always the module its types are printed under (`SwiftUI`).
        public let moduleName: String

        /// Whether the discriminator belongs to the file the compiler synthesizes for `fileName`,
        /// whose discriminator is the MD5 of that file's own followed by `SYNTHESIZED FILE`
        /// (`SynthesizedFileUnit::getDiscriminatorForPrivateDecl`).
        public let isSynthesized: Bool

        public init(fileName: String, moduleName: String, isSynthesized: Bool) {
            self.fileName = fileName
            self.moduleName = moduleName
            self.isSynthesized = isSynthesized
        }
    }

    /// Words that often end a file name, tried after every run of words (step 4). Each was the
    /// last word of a SwiftUICore file name nothing else recovered.
    private static let fileNameSuffixes = ["Additions", "Conversions", "Utils", "Helpers", "Modifier", "Style", "View", "Environment", "Core", "s"]

    private let sourceFileByDiscriminator: [String: SourceFile]

    /// Recovers the source files of `discriminators`.
    ///
    /// - Parameters:
    ///   - discriminators: The discriminators to recover. Every candidate costs one hash per module
    ///     name, and a discriminator nothing recovers is hashed against all of them: in a debug
    ///     build that takes three to four seconds for SwiftUICore, and a whole image's take
    ///     minutes. Ask for the ones shown.
    ///   - imagePath: The image the objects come from. Its file name is the first module name tried.
    ///   - runtimeObjects: Every object in the image; their children are walked too. Their names
    ///     make the candidates, and their `privateDeclarations` say which names were declared in
    ///     the same file.
    ///   - knownFileNames: File names to try before any is derived from the image's names.
    public init(
        recovering discriminators: some Sequence<String>,
        imagePath: String,
        runtimeObjects: some Sequence<RuntimeObject>,
        knownFileNames: [String] = RuntimePrivateDiscriminatorSourceFiles.knownFileNames
    ) {
        var moduleNames = Self.moduleNames(forImagePath: imagePath)
        var knownModuleNames = Set(moduleNames)
        var identifiers: Set<String> = []
        var identifiersByDiscriminator: [String: Set<String>] = [:]
        func collect(_ runtimeObject: RuntimeObject) {
            var objectIdentifiers: Set<String> = []
            Self.collectIdentifiers(in: runtimeObject.displayName, into: &objectIdentifiers)
            identifiers.formUnion(objectIdentifiers)
            if !runtimeObject.privateDeclarations.isEmpty {
                // Only a name with a private declaration names a module the digests were made in;
                // an Objective-C class has no module part, and every name taken here multiplies the
                // work.
                if let moduleName = Self.leadingModuleName(of: runtimeObject.displayName), knownModuleNames.insert(moduleName).inserted {
                    moduleNames.append(moduleName)
                }
                for privateDeclaration in runtimeObject.privateDeclarations {
                    identifiersByDiscriminator[privateDeclaration.discriminator, default: []].formUnion(objectIdentifiers)
                }
            }
            for child in runtimeObject.children {
                collect(child)
            }
        }
        for runtimeObject in runtimeObjects {
            collect(runtimeObject)
        }

        var search = Search(
            moduleNames: moduleNames,
            requestedDiscriminators: Set(discriminators),
            imageDiscriminators: Set(identifiersByDiscriminator.keys)
        )
        Self.recover(into: &search, knownFileNames: knownFileNames, identifiers: identifiers, identifiersByDiscriminator: identifiersByDiscriminator)
        self.sourceFileByDiscriminator = search.sourceFileByDiscriminator
    }

    /// Tries the candidates of each step in turn, and returns as soon as every discriminator asked
    /// for is found — before building the next step's candidates, which cost more than the hashing
    /// of the steps before.
    private static func recover(into search: inout Search, knownFileNames: [String], identifiers: Set<String>, identifiersByDiscriminator: [String: Set<String>]) {
        // 1. Known file names.
        for knownFileName in knownFileNames {
            guard !search.isComplete else { return }
            search.check(NamePart(knownFileName))
        }

        // 2. Identifiers and their runs of words.
        guard !search.isComplete else { return }
        var stemTexts: Set<String> = []
        for identifier in identifiers {
            stemTexts.formUnion(fileNameStems(for: identifier))
        }
        let stems = stemTexts.map(NamePart.init)
        for stem in stems {
            guard !search.isComplete else { return }
            search.check(stem, NamePart.swiftFileExtension)
        }

        // 3. Two words declared with the same discriminator.
        var categoriesByDiscriminator: [String: [NamePart]] = [:]
        func categories(for discriminator: String) -> [NamePart] {
            if let categories = categoriesByDiscriminator[discriminator] {
                return categories
            }
            var categoryTexts: Set<String> = []
            for identifier in identifiersByDiscriminator[discriminator] ?? [] {
                categoryTexts.formUnion(fileNameStems(for: identifier).filter { $0.utf8.first.map(isUppercaseLetter) ?? false })
            }
            let categories = categoryTexts.sorted().map(NamePart.init)
            categoriesByDiscriminator[discriminator] = categories
            return categories
        }
        for discriminator in search.pendingDiscriminators {
            let categories = categories(for: discriminator)
            for type in categories {
                for category in categories where category.text != type.text {
                    guard search.isPending(discriminator) else { break }
                    search.check(type, NamePart.plusSign, category, NamePart.swiftFileExtension)
                }
            }
        }

        // 4. Runs of words followed by a common last word.
        for suffix in fileNameSuffixes {
            let suffixWithExtension = NamePart(suffix + ".swift")
            for stem in stems {
                guard !search.isComplete else { return }
                search.check(stem, suffixWithExtension)
            }
        }

        // 5. Any type name before a word declared with the discriminator.
        let typeNames = identifiers.filter { $0.utf8.first.map(isUppercaseLetter) ?? false }.sorted().map(NamePart.init)
        for discriminator in search.pendingDiscriminators {
            let categories = categories(for: discriminator)
            for type in typeNames {
                guard search.isPending(discriminator) else { break }
                for category in categories where category.text != type.text {
                    search.check(type, NamePart.plusSign, category, NamePart.swiftFileExtension)
                }
            }
        }
    }

    /// The source file `discriminator` was derived from, or `nil` when it was not asked for or no
    /// candidate produced it.
    public func sourceFile(forDiscriminator discriminator: String) -> SourceFile? {
        sourceFileByDiscriminator[discriminator]
    }

    // MARK: - Module Names

    /// The module names an image's own file name suggests, most likely first: the name itself
    /// (`SwiftUICore`), what Xcode makes of it as a module name (`My App` → `My_App`), and the name
    /// left after a library prefix (`libswiftAppKit.dylib` → `AppKit`).
    private static func moduleNames(forImagePath imagePath: String) -> [String] {
        let fileName = ((imagePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var moduleNames: [String] = []
        func append(_ moduleName: String) {
            guard !moduleName.isEmpty, !moduleNames.contains(moduleName) else { return }
            moduleNames.append(moduleName)
        }
        append(fileName)
        append(identifierSpelling(of: fileName))
        for libraryPrefix in ["libswift", "lib"] where fileName.hasPrefix(libraryPrefix) {
            append(String(fileName.dropFirst(libraryPrefix.count)))
            break
        }
        return moduleNames
    }

    /// `name` with every character that cannot appear in an identifier replaced by `_`, and a `_`
    /// in front of a leading digit — the spelling Xcode gives a product's module name.
    private static func identifierSpelling(of name: String) -> String {
        var bytes = name.utf8.map { isIdentifierByte($0) && $0 < 0x80 ? $0 : UInt8(ascii: "_") }
        if let firstByte = bytes.first, isDigit(firstByte) {
            bytes.insert(UInt8(ascii: "_"), at: 0)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The module part of a Swift display name, `SwiftUI` in `SwiftUI.EnabledKey`.
    private static func leadingModuleName(of displayName: String) -> String? {
        guard let dotIndex = displayName.firstIndex(of: ".") else { return nil }
        let moduleName = displayName[..<dotIndex]
        guard !moduleName.isEmpty, moduleName.utf8.allSatisfy(isIdentifierByte) else { return nil }
        return String(moduleName)
    }

    // MARK: - Candidates

    /// Adds every identifier `displayName` spells to `identifiers`.
    private static func collectIdentifiers(in displayName: String, into identifiers: inout Set<String>) {
        let bytes = Array(displayName.utf8)
        var index = 0
        while index < bytes.count {
            guard isIdentifierByte(bytes[index]) else {
                index += 1
                continue
            }
            let identifierStartIndex = index
            while index < bytes.count, isIdentifierByte(bytes[index]) {
                index += 1
            }
            identifiers.insert(String(decoding: bytes[identifierStartIndex ..< index], as: UTF8.self))
        }
    }

    /// The file names, without their extension, that `identifier` suggests: the identifier as it
    /// is and without its leading underscores, and every run of its camel-case words.
    private static func fileNameStems(for identifier: String) -> Set<String> {
        var stems: Set<String> = [identifier]
        let strippedBytes = Array(identifier.utf8.drop { $0 == UInt8(ascii: "_") })
        guard !strippedBytes.isEmpty else { return stems }
        stems.insert(String(decoding: strippedBytes, as: UTF8.self))
        guard strippedBytes.allSatisfy({ $0 < 0x80 }) else { return stems }
        let wordRanges = camelCaseWordRanges(in: strippedBytes)
        for firstWordIndex in wordRanges.indices {
            for endWordIndex in firstWordIndex + 1 ... wordRanges.count {
                stems.insert(String(decoding: wordRanges[firstWordIndex ..< endWordIndex].flatMap { strippedBytes[$0] }, as: UTF8.self))
            }
        }
        return stems
    }

    /// The ranges of `bytes`' camel-case words: `URL`, `Session` in `URLSession`; `UI`, `2` in
    /// `UI2`. Underscores separate words and belong to none.
    private static func camelCaseWordRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var wordRanges: [Range<Int>] = []
        var index = 0
        func lowercaseOrDigitRunEnd(from startIndex: Int) -> Int {
            var endIndex = startIndex
            while endIndex < bytes.count, isLowercaseLetter(bytes[endIndex]) || isDigit(bytes[endIndex]) {
                endIndex += 1
            }
            return endIndex
        }
        while index < bytes.count {
            let byte = bytes[index]
            if isUppercaseLetter(byte) {
                var uppercaseRunEndIndex = index
                while uppercaseRunEndIndex < bytes.count, isUppercaseLetter(bytes[uppercaseRunEndIndex]) {
                    uppercaseRunEndIndex += 1
                }
                let isFollowedByLowercase = uppercaseRunEndIndex < bytes.count && isLowercaseLetter(bytes[uppercaseRunEndIndex])
                if !isFollowedByLowercase {
                    // An acronym that ends the name or comes before a digit: `UI`.
                    wordRanges.append(index ..< uppercaseRunEndIndex)
                    index = uppercaseRunEndIndex
                } else if uppercaseRunEndIndex - index > 1 {
                    // An acronym before a capitalized word: `URL` in `URLSession`.
                    wordRanges.append(index ..< uppercaseRunEndIndex - 1)
                    index = uppercaseRunEndIndex - 1
                } else {
                    // A capitalized word: `Session`.
                    let wordEndIndex = lowercaseOrDigitRunEnd(from: uppercaseRunEndIndex)
                    wordRanges.append(index ..< wordEndIndex)
                    index = wordEndIndex
                }
            } else if isLowercaseLetter(byte) || isDigit(byte) {
                let wordEndIndex = lowercaseOrDigitRunEnd(from: index)
                wordRanges.append(index ..< wordEndIndex)
                index = wordEndIndex
            } else {
                index += 1
            }
        }
        return wordRanges
    }

    // MARK: - Bytes

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isLowercaseLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "_") || byte >= 0x80
    }

    private static func isUppercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }
}

// MARK: - Search

extension RuntimePrivateDiscriminatorSourceFiles {
    /// A piece of a candidate file name, kept with its bytes so a candidate is hashed without
    /// being assembled.
    fileprivate struct NamePart {
        static let swiftFileExtension = NamePart(".swift")

        static let plusSign = NamePart("+")

        let text: String

        let bytes: [UInt8]

        init(_ text: String) {
            self.text = text
            self.bytes = Array(text.utf8)
        }
    }

    /// The discriminators still looked for, and the source files found so far.
    fileprivate struct Search {
        private static let synthesizedFileSuffix = Array("SYNTHESIZED FILE".utf8)

        private let moduleNames: [NamePart]

        /// Every discriminator still looked for, by digest: those asked for, and those of the
        /// files the compiler synthesized one of them for.
        private var pendingDiscriminatorByDigest: [Digest128: String] = [:]

        /// The discriminator of the file the compiler synthesized for each of the image's
        /// discriminators, where it is one of those asked for.
        private let synthesizedDiscriminatorByOwnerDiscriminator: [String: String]

        private var remainingRequestedDiscriminators: Set<String>

        private(set) var sourceFileByDiscriminator: [String: SourceFile] = [:]

        init(moduleNames: [String], requestedDiscriminators: Set<String>, imageDiscriminators: Set<String>) {
            self.moduleNames = moduleNames.map(NamePart.init)
            var requestedDiscriminatorByDigest: [Digest128: String] = [:]
            for requestedDiscriminator in requestedDiscriminators {
                if let digest = Digest128(discriminator: requestedDiscriminator) {
                    requestedDiscriminatorByDigest[digest] = requestedDiscriminator
                }
            }
            self.remainingRequestedDiscriminators = Set(requestedDiscriminatorByDigest.values)
            self.pendingDiscriminatorByDigest = requestedDiscriminatorByDigest
            // A synthesized file has no name of its own to hash: its owner is looked for instead,
            // among the discriminators the image declares something with.
            var synthesizedDiscriminatorByOwnerDiscriminator: [String: String] = [:]
            for ownerDiscriminator in imageDiscriminators {
                var hashFunction = Insecure.MD5()
                hashFunction.update(data: Array(ownerDiscriminator.utf8))
                hashFunction.update(data: Self.synthesizedFileSuffix)
                guard let synthesizedDiscriminator = requestedDiscriminatorByDigest[Digest128(hashFunction.finalize())],
                      let ownerDigest = Digest128(discriminator: ownerDiscriminator)
                else { continue }
                synthesizedDiscriminatorByOwnerDiscriminator[ownerDiscriminator] = synthesizedDiscriminator
                pendingDiscriminatorByDigest[ownerDigest] = ownerDiscriminator
            }
            self.synthesizedDiscriminatorByOwnerDiscriminator = synthesizedDiscriminatorByOwnerDiscriminator
        }

        /// Whether every discriminator asked for has been found.
        var isComplete: Bool {
            remainingRequestedDiscriminators.isEmpty
        }

        /// The discriminators still looked for, sorted so that a search runs the same every time.
        var pendingDiscriminators: [String] {
            pendingDiscriminatorByDigest.values.sorted()
        }

        func isPending(_ discriminator: String) -> Bool {
            sourceFileByDiscriminator[discriminator] == nil && !isComplete
        }

        /// Hashes the file name `parts` spell, under every module name.
        mutating func check(_ parts: NamePart...) {
            for moduleName in moduleNames {
                var hashFunction = Insecure.MD5()
                moduleName.bytes.withUnsafeBytes { hashFunction.update(bufferPointer: $0) }
                for part in parts {
                    part.bytes.withUnsafeBytes { hashFunction.update(bufferPointer: $0) }
                }
                let digest = Digest128(hashFunction.finalize())
                guard let discriminator = pendingDiscriminatorByDigest[digest] else { continue }
                record(sourceFile(hashedAs: moduleName, followedBy: parts), for: discriminator, digest: digest)
                return
            }
        }

        /// The source file `moduleName` followed by `parts` names — read under the first module
        /// name the same bytes start with. When one module name starts another, one digest has two
        /// readings: `SwiftUICoreGlue.swift` is `Glue.swift` in SwiftUICore and `CoreGlue.swift`
        /// in SwiftUI. The module names come most likely first, so the reading does not depend on
        /// which candidate happened to be tried first.
        private func sourceFile(hashedAs moduleName: NamePart, followedBy parts: [NamePart]) -> SourceFile {
            let hashedBytes = moduleName.bytes + parts.flatMap(\.bytes)
            for earlierModuleName in moduleNames.prefix(while: { $0.text != moduleName.text }) where hashedBytes.starts(with: earlierModuleName.bytes) {
                let fileNameBytes = hashedBytes.dropFirst(earlierModuleName.bytes.count)
                guard let firstByte = fileNameBytes.first, firstByte != UInt8(ascii: ".") else { continue }
                return SourceFile(fileName: String(decoding: fileNameBytes, as: UTF8.self), moduleName: earlierModuleName.text, isSynthesized: false)
            }
            return SourceFile(fileName: parts.map(\.text).joined(), moduleName: moduleName.text, isSynthesized: false)
        }

        private mutating func record(_ sourceFile: SourceFile, for discriminator: String, digest: Digest128) {
            pendingDiscriminatorByDigest[digest] = nil
            sourceFileByDiscriminator[discriminator] = sourceFile
            remainingRequestedDiscriminators.remove(discriminator)
            guard let synthesizedDiscriminator = synthesizedDiscriminatorByOwnerDiscriminator[discriminator],
                  sourceFileByDiscriminator[synthesizedDiscriminator] == nil,
                  let synthesizedDigest = Digest128(discriminator: synthesizedDiscriminator)
            else { return }
            pendingDiscriminatorByDigest[synthesizedDigest] = nil
            sourceFileByDiscriminator[synthesizedDiscriminator] = SourceFile(fileName: sourceFile.fileName, moduleName: sourceFile.moduleName, isSynthesized: true)
            remainingRequestedDiscriminators.remove(synthesizedDiscriminator)
        }
    }
}

// MARK: - Digest128

/// An MD5 digest as two words, so a candidate's digest is looked up without building its
/// hexadecimal spelling.
private struct Digest128: Hashable {
    let leadingBits: UInt64
    let trailingBits: UInt64

    /// Reads the digest in place: every candidate makes one, so it allocates nothing.
    init(_ digest: Insecure.MD5Digest) {
        let bits = digest.withUnsafeBytes { buffer in
            (leading: UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
             trailing: UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        self.leadingBits = bits.leading
        self.trailingBits = bits.trailing
    }

    /// Reads a discriminator: `_` followed by 32 uppercase hexadecimal digits.
    init?(discriminator: String) {
        let digits = Array(discriminator.utf8.dropFirst())
        guard discriminator.utf8.first == UInt8(ascii: "_"), digits.count == 32 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        for byteIndex in 0 ..< 16 {
            guard let highNibble = Self.nibble(digits[byteIndex * 2]), let lowNibble = Self.nibble(digits[byteIndex * 2 + 1]) else { return nil }
            bytes[byteIndex] = highNibble << 4 | lowNibble
        }
        self.init(bytes: bytes)
    }

    private init(bytes: [UInt8]) {
        var leadingBits: UInt64 = 0
        var trailingBits: UInt64 = 0
        for index in 0 ..< 8 {
            leadingBits = leadingBits << 8 | UInt64(bytes[index])
            trailingBits = trailingBits << 8 | UInt64(bytes[index + 8])
        }
        self.leadingBits = leadingBits
        self.trailingBits = trailingBits
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
