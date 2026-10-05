---
name: runtime-viewer-cli
description: >-
  Reading Objective-C and Swift interfaces, class hierarchies and member addresses from a live
  runtime — this Mac, Mac Catalyst, an attached process, a Bonjour peer — with
  runtime-viewer-cli, RuntimeViewer's command-line tool: images, types, search, interface,
  members, specialize, export, sources, attach and its background host. Read before running
  it. Triggers on runtime-viewer-cli, RuntimeViewer CLI, "export this framework's headers".
---

# runtime-viewer-cli

RuntimeViewer without its window. The tool runs the same engine as the
[RuntimeViewer](https://github.com/MxIris-Reverse-Engineering/RuntimeViewer) app and its MCP
server, driven from a shell or a script: list images and types, print a type's Objective-C or
Swift interface, its hierarchy, relationships and member addresses, specialize a generic Swift
type, or export every interface of an image to disk — as text or as JSON.

**It reads a live runtime, never a file at rest.** Every answer comes from a process running
now: this Mac's local runtime, its Mac Catalyst runtime, a process you attach to, or another
RuntimeViewer reached over Bonjour. So every answer — declarations and addresses alike — belongs
to the OS build those processes run. It cannot read an archived dyld shared cache of another OS
version, or a binary built for another platform; use a static Mach-O reader for those, such as
the `swift-section` CLI (the `swift-section-cli` skill of the `swift-section` plugin).

## 0. Find the tool

RuntimeViewer ships it inside the app from 3.0.0-beta.5 on, signed and notarised with it:

```bash
command -v runtime-viewer-cli \
  || ls /Applications/RuntimeViewer.app/Contents/Applications/runtime-viewer-cli
runtime-viewer-cli --version
```

There is no installer step: to call it by its short name, symlink that file into a directory on
`PATH`. A checkout of the repository also builds it — `swift build -c release --product
runtime-viewer-cli` in `RuntimeViewerCommandLine/`, macOS 15 or later. Build release: a debug
build pairs with the debug app and never sees the released one (§5).

`runtime-viewer-cli help <subcommand>` is generated from the code and is authoritative for every
flag. For the `host` subcommands write `runtime-viewer-cli host <subcommand> --help` —
`help host run` falls back to the top-level help.

## 1. Pick the command

| The question | Command |
|---|---|
| Which images can be queried | `images [--loaded] [--query <text>]` |
| Load a Mach-O by path and index it | `load <path>` |
| The types of an image | `types --image <image> [--kind <kind>]...` |
| The exact name of a type | `search <text> [--image <image>] [--regex] [--kind <kind>]...` |
| A type's declaration | `interface <type> --image <image> [--full \| --options default\|full\|app]` |
| Its superclass chain | `hierarchy <type> --image <image>` |
| Its subclasses and conforming types, across the loaded images | `relationships <type> --image <image>` |
| The implementation addresses of its members | `members <type> --image <image> [--member <text>]` |
| A generic Swift type with its parameters bound | `specialize <type> --image <image> --list`, then one `--argument <Parameter>=<Type>` per parameter |
| Every interface of one image, on disk | `export <image> --output <directory> [--full] [--objc single\|directory] [--swift single\|directory] [--no-metadata]` |
| Which sources the host can reach, and how to name each | `sources [--wait <seconds>]` |
| A running process as a source | `attach <pid \| name>`, later `detach` (§6) |
| The background host | `host [status]`, `host stop`, `host restart`, `host run` (§5) |

Every subcommand also takes `--source <selector>` (§2), `--json` (§3), `--timeout <seconds>`
and `--no-spawn` (fail instead of starting a host). `--kind` takes `objc-class`,
`objc-protocol`, `objc-category`, `swift-class`, `swift-struct`, `swift-enum`,
`swift-protocol`, `swift-typealias`, `swift-extension`, `swift-conformance`, `c-struct`,
`c-union`.

The usual lookup is three commands — find the exact name, read the declaration, take the
addresses:

```bash
runtime-viewer-cli search TextInput --image AppKit
runtime-viewer-cli interface NSTextInputContext --image AppKit --full
runtime-viewer-cli members NSTextInputContext --image AppKit --member insertText
```

## 2. How names resolve

### Images: `--image`

- An absolute path is taken as is. A short name is looked up in the images already loaded,
  then the images mapped into the host process, then the system catalog (the shared cache and
  the framework directories). Each step tries the file name without its extension, exactly and
  case-insensitively, before trying it as a substring, and several hits resolve to the first by
  full path — the answer does not depend on how warm the host is. `--image AppKit` works on a
  fresh host; `--image objc` hits `libobjc.A.dylib`.
- **Without `--image`, only images already loaded are searched**, and a fresh host has none:
  the command fails with `imageNotFound`. Pass `--image`, or `load` the image first.
- The client turns paths into absolute ones before they reach the host, whose working directory
  has nothing to do with yours. **A bare name that is a regular file in the current directory
  counts as a path**: with a file called `AppKit` in the working directory, `--image AppKit`
  reads that file, not the framework. Directories never count.
- `export` needs a name that resolves to exactly one image.

### Types

The type argument is matched against the type's `name`, then its `displayName`, then either one
case-insensitively, descending into specializations that already exist. A Swift type's
`displayName` is **module-qualified** and its `name` is a mangled form, so it is
`Combine.Just`, never `Just` — the bare name fails with `typeNotFound`. When unsure, `search`
first and copy the name it prints.

### Sources: `--source`

| Selector | Reaches |
|---|---|
| `local` (default) | The local runtime of the host |
| `catalyst` | The Mac Catalyst runtime; needs the helper daemon and the Catalyst helper inside RuntimeViewer.app |
| `pid:<n>` | A process attached earlier, by process identifier |
| `process:<name>` | A process attached earlier, by name, case-insensitively; several matches are an error that lists their `pid:` selectors |
| `engine:<id>` | Any engine the host knows — Bonjour peers and the engines they forward; the identifier changes when the peer reconnects |

`sources` prints every selector the host can serve, grouped by host. A host that has just
started brings its engines up asynchronously and retries a miss every 100 ms for 8 s, so a
selector that really does not exist takes those 8 s to fail with `sourceUnavailable`.

## 3. Reading the output

### Annotations: `--options` and `--full`

| `--options` | What the output carries |
|---|---|
| `default` (the default) | The library defaults — **no address or offset comments** |
| `full`, or `--full` | Everything — the set the app's MCP server uses |
| `app` | Whatever the RuntimeViewer app is configured to show: read live when the app is the host, otherwise from its saved settings |

With `--full`, an Objective-C method ends in `// IMP: 0x…`, a property in
`// getter IMP: 0x… // setter IMP: 0x…`, an ivar in `// offset: <n>`. A Swift member gets its
comments on the lines **above** it: `// Address: 0x…`, `// Address (getter): 0x…`,
`// VTable offset: <n>`.

`members` prints `ADDRESS`, `KIND`, `NAME` and `SYMBOL` for each member; `--member` is a
case-insensitive substring filter on the name.

**Addresses are unslid virtual addresses** — what a disassembler shows for the image on disk or
in the dyld shared cache. They are valid in a database built from the same build, which for a
shared-cache image means a cache with the same UUID, and in no other.

### `--json`

Standard output then carries exactly one JSON document: the result, or
`{"error":{"code":…,"message":…}}`. Progress and warnings always go to standard error, so a
script can parse standard output whole. A type appears as `name`, `displayName`, `kind`,
`imagePath` and `imageName`; `kind` is a display string such as `Objective-C Class` or
`Swift Struct`, not a `--kind` value.

### Exit status

| Status | Meaning |
|---|---|
| `0` | Success |
| `1` | The command failed. The code is `error.code` in JSON, or the bracketed word ending the message on standard error (`… [typeNotFound]`) |
| `64` | Bad arguments |
| `69` | No host was running and none could be started — or `--no-spawn` was given |

The failure codes: `imageNotFound`, `imageLoadFailed`, `typeNotFound`, `sourceUnavailable`,
`invalidArgument`, `specializationFailed`, `exportFailed`, `helperUnavailable`,
`applicationBundleNotFound`, `processNotFound`, `ambiguousProcessName`, `attachFailed`,
`hostBusy`, `unsupportedProtocolVersion`, `cancelled`, `internalError`.

## 4. Exporting a whole image

```bash
runtime-viewer-cli export AppKit --output ./AppKit-Interfaces \
  --full --objc directory --swift directory
```

- `--objc` and `--swift` default to `single`: one `<Image>.h` and one `<Image>.swiftinterface`.
  `directory` writes `ObjCHeaders/` and `SwiftInterfaces/` with one file per type, which is
  what lets a type be found by file name.
- A `README.md` beside them records the provenance: the tool's version and commit, the image's
  path, bundle versions, install name and Mach-O UUID, the counts — `Failed:` says whether every
  type made it — and every option used. `--no-metadata` leaves it out.
- **Without `--full` the files carry no address comments.**
- The output directory is created when missing but never emptied: files of the same name are
  overwritten and everything else stays. Export into a fresh directory, or one export ends up
  mixed with another.
- Progress goes to standard error. An export is not retried when the connection to the host
  drops; run it again.

## 5. The background host

The tool is a client. The first command starts a background **host** process (`host run`) that
owns the runtime engines and keeps their indexes warm; later commands reuse it, and a cold
start costs a few seconds of indexing.

- **It exits by itself** after 600 s without connections or commands, and the next command
  starts a new one. `RUNTIME_VIEWER_CLI_IDLE_TIMEOUT` (seconds, `0` for never) changes that for
  the hosts the tool starts.
- **A running RuntimeViewer app is the host.** On launch it takes over from a standalone host,
  and from then on its attached processes and Bonjour peers are sources for the tool too.
  `host status` shows who is serving: `Kind: application` or `Kind: standalone`. When the app
  quits, the next command starts a standalone host again.
- **Debug and release builds are separate worlds.** A release tool keeps its socket and records
  in `~/Library/Application Support/RuntimeViewer/CommandLineHost/` and pairs with the released
  app; a debug build uses `RuntimeViewer-Debug/` and the debug app. Neither sees the other's
  host. `RUNTIME_VIEWER_CLI_HOST_DIRECTORY` moves the directory.
- `host.log` in that directory holds the output of a host the tool started. To watch one
  directly, run `runtime-viewer-cli host run --idle-timeout 0` in the foreground.
- A host serves only its own user: the socket is `0600` and the peer's uid is checked.
- `--timeout` bounds the whole call — waiting for the start-up lock, starting the host, and its
  answer — so it is a real upper bound for a script.
- When the connection drops, a read-only command is retried once; `export`, `attach` and
  `detach` never are.
- A standalone host speaking a different protocol version is replaced automatically. An app
  that does is an error: update the app or the tool.

## 6. Attaching to a running process

`attach <pid | name>` injects RuntimeViewer into a running process and makes its runtime a
source, then prints the selector to use — `pid:<n>` for a Mac process, `engine:<id>` for a
Simulator process. It changes the target process: use it only when the question is about that
live process.

- **Prerequisites** are the app's: System Integrity Protection disabled, the helper daemon
  installed (RuntimeViewer → Settings → Helper Service), and a RuntimeViewer.app to take the
  injected payload from. A standalone host looks for the app through `host run --app-bundle`,
  then `$RUNTIME_VIEWER_APP_BUNDLE`, then the app enclosing the tool, then the installed app;
  when all four fail, `attach` reports `applicationBundleNotFound`.
- A name matches the process name or the executable's file name, exactly and
  case-insensitively; several matches fail with `ambiguousProcessName` and list their pids. A
  process attached before is answered from its existing engine, never injected twice.
- Every host that starts reconnects the processes injected earlier. `detach` drops one: it
  stays injected but is no longer a source and is not reconnected. The record of injected
  processes is shared by debug and release builds.

## 7. Traps

- **`images` without `--loaded` lists thousands of shared-cache images.** Pair it with
  `--query`.
- **`Socket path is longer than 103 bytes`** — a long user name pushes the default host
  directory past the Unix-socket path limit. Point `RUNTIME_VIEWER_CLI_HOST_DIRECTORY` at a
  short directory such as `/tmp/rvcli`.
- **`specialize` binds only leaf candidates.** A candidate that is generic itself (marked
  `generic` in `--list`) needs the app.
- **`sources --wait` answers early once the list has not changed for 3 s.** A peer found just
  before that may still show as not connected — run it again.
- **`detach` on a Bonjour peer only disconnects it**; the browser may find it and connect
  again.
- **A debug tool next to the released app**: the debug standalone host sees the running release
  app as a Bonjour peer and mirrors its engines. Use the release tool to avoid the duplicates.
