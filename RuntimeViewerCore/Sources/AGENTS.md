# AGENTS.md — RuntimeViewerCore sources

Where a file goes in this package's six Swift targets. Background:
`Documentations/Evolutions/0073-core-source-layout.md`.

## One top-level type per file

- Every top-level type gets a file named after it (`RuntimeObjectKey.swift`). An extension of a type
  declared elsewhere gets one named `ExtendedType+Purpose.swift` (`RuntimeEngine+Search.swift`,
  `String+PathComponents.swift`).
- A type's own extensions stay in its file. One that belongs to another feature goes into that
  feature's directory as `Type+Feature.swift`, the way each feature's `RuntimeEngine+Feature.swift`
  does.
- These stay with the type they serve instead of getting a file: `private` and `fileprivate` helper
  types and extensions; nested types, which stay inside their parent or in the extension that declares
  them (the command structs of `RuntimeEngine+Commands.swift`); a typealias, global variable or function
  only one type uses. `HelperService/RuntimeRequests.swift`, a list of one-line retroactive
  conformances, is the one file that holds several.
- A member that a type in another file needs is `internal`, not `fileprivate`. Splitting the old
  multi-type files widened a few for that reason: the XPC connection base classes' members their
  subclasses use, and the `RuntimeSwiftSection` methods its factory calls.
- `@Loggable`'s logger is private to the file that declares it. An extension in a file of its own that
  logs, a `RuntimeEngine` extension above all, gets a `private` log type of its own
  (`RuntimeEngineCommandExtensionLog` in `Engine/Commands/RuntimeEngine+CommandExtensions.swift`).
- File names are unique within a module: the compiler rejects two files with the same name.
- No directory may be called `build`, `Products`, `DerivedData` or `Archives`. The repository's
  `.gitignore` ignores those names anywhere, and git on macOS matches them regardless of case; that is
  why the derived data code lives in `DerivedDataStorage/`.

## Directories by feature

A feature's models, its implementation and its `RuntimeEngine+Feature.swift` share a directory. Models
that several features use live in `Objects/`, `Interfaces/` and `Images/`.

`RuntimeViewerCore`:

| Directory | What it holds |
|-----------|---------------|
| `Engine/` | `RuntimeEngine` itself, and what every feature uses: host info, data change events, image path canonicalization |
| `Engine/Commands/` | The command mechanism: `RuntimeEngineCommand`, command names, the registrar, progress envelopes, withdrawing and forwarding requests |
| `Engine/Serving/` | Serving an engine to other processes: the connection server, the proxy server, remote engine descriptors |
| `Images/` | Where an engine's images come from and how they are read: reading modes, catalogs, the image index, image nodes, dyld helpers |
| `Objects/` | `RuntimeObject`, its kinds and counterparts, member addresses, private declarations, loading progress |
| `Interfaces/` | `RuntimeObjectInterface`, its wire response, comment structure, text ranges, Swift generation options |
| `Sections/`, `Sections/ObjC/`, `Sections/Swift/` | An image's Objective-C and Swift sections, their factories and interface indexers, and the protocols the engine holds them through |
| `Search/`, `Search/Corpus/`, `Search/Matching/` | Find: query and result models; building, keeping and snapshotting the corpora; text and member matching |
| `Relationships/` | The Inspector's relationship rows and the Find navigator's relationship trees |
| `Specialization/` | Generic specialization |
| `Bookmarks/` | Bookmarks and bookmark scopes |
| `SharedCache/` | Borrowing shared cache images from the engines that own them: the owners, handing a request about one image to its owner, and combining the answers of a request about every image |
| `BackgroundIndexing/`, `Export/`, `DerivedDataStorage/`, `Offline/` | Those features |
| `LocalService/` | The local XPC service's key, credential and the host its services run |
| `Transformer/` | `Transformer.Configuration` and the transformer modules it re-exports |
| `Extensions/` | Standard library extensions |

`RuntimeViewerCommunication`: `RuntimeSource`, `RuntimeDeviceMetadata` and `RuntimeCommunicator` at the
root. `Connections/` holds the connection protocols and what every transport shares, with one directory
per transport: `DirectTCP/`, `LocalSocket/`, `Network/` (with the Bonjour discovery), `Stdio/`,
`XPCMachService/`, `XPCService/`. `Messaging/` holds the message channel, `HelperService/` the helper
daemon's request protocols, its mach service name and the protocol version.

`RuntimeViewerCrossReferences`: the commands and the engine interface at the root, the wire types in
`Models/`, scanning and querying in `Analysis/`. `RuntimeViewerInjection`, `RuntimeViewerService` (the
helper daemon's entry point) and `RuntimeViewerUtilities` are flat.

This file sits in `Sources/` rather than in a target's directory because SwiftPM reports any file it
has no rule for inside a target as unhandled.
