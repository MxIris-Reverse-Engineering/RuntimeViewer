# AGENTS.md
This file provides guidance to coding agents when working with code in this repository.

## Project Overview

Runtime Viewer is a macOS/iOS document-based (NSDocument) application for inspecting Objective-C and Swift runtime interfaces. It serves as a modern alternative to RuntimeBrowser with features like Swift interface support, type-defined jumps, Xcode-style syntax highlighting, code injection capabilities, and MCP (Model Context Protocol) integration for LLM clients.

## Where the Rules Live

This file holds what nearly every task needs. A rule that matters only for one part of the tree lives in
an `AGENTS.md` of its own, with a `CLAUDE.md` symlink beside it as here, in the directory it governs.
**Read the file covering what you change before changing it:**

| File | Covers |
|------|--------|
| `RuntimeViewerUsingAppKit/AGENTS.md` | The macOS app's UI layer — ViewModels, ViewControllers, cells and cell ViewModels, coordinators and routes, AppKit views, the sidebar's floating bars, diagnosing flicker — and `AppDelegate` with the lifecycle controllers. It also governs the ViewModels and routes in `RuntimeViewerApplication` and the views in `RuntimeViewerUI` |
| `RuntimeViewerPackages/Sources/AGENTS.md` | What goes in `RuntimeViewerAppCore` and what in `RuntimeViewerAppUI`, and the facade `RuntimeViewerApplication`; points their UI code and `RuntimeViewerUI` to the file above |
| `RuntimeViewerPackages/Tests/AGENTS.md` | Keeping package tests off the user's real settings, bookmarks and derived data; engines in tests |
| `RuntimeViewerCore/Sources/AGENTS.md` | Where a file goes in the RuntimeViewerCore package: one top-level type per file, directories by feature; how every engine command declares its routing |
| `RuntimeViewerCore/Tests/AGENTS.md` | Keeping Core tests off the user's real derived data |
| `RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md` | The SourceEditor module, wherever its files are (see *SourceEditor Module* below) |
| `Configurations/AGENTS.md` | Per-target build settings: the embedded non-macOS products, the jailbroken variant's payload, service names, adding a configuration |
| `Resources/AGENTS.md` | The app icons |

Put a new rule in the narrowest directory it governs — but **never put an `AGENTS.md` or `CLAUDE.md` in an
Xcode synchronized folder or a SwiftPM target's directory**; use the nearest directory above. Every target
folder under `RuntimeViewerUsingAppKit/` and `RuntimeViewerServer/` is synchronized with its target, so a
file put there becomes a bundle resource of the target (two with the same name fail the build with
"Multiple commands produce"), and SwiftPM warns about any file it has no rule for in `Sources/<Target>/`
or `Tests/<Target>/`. Keep this file well under 64 KiB: the Codex configuration used with this repository
reads only that much of it (`project_doc_max_bytes`) and drops the rest without a word, and Claude Code
warns once all instruction files together pass 150,000 characters.

<important if="you need to build, test, run, archive or release this project, or update its package pins">

## Build Commands

**Workspaces**: `RuntimeViewer-Debug.xcworkspace` (used by `RunScript.sh`) and
`RuntimeViewer-Distribution.xcworkspace` (release archives) hold this repository's four packages, its
projects and the precompiled swift-syntax, and take every other package at the version their committed
`Package.resolved` pins. **`RuntimeViewer-Local.xcworkspace` adds the local checkouts of MachOKit,
MachOKitExtensions, MachOObjCSection, MachOSwiftSection, swift-demangling and swift-semantic-string**
(the links of those names in the `.worktrees/` beside this checkout), which replace those six packages
everywhere in the graph: open it to build changes in them before they are pushed, and the Debug workspace
to build against the pins; a project is open in one workspace at a time. Do not switch some manifests'
local candidates on instead — the libraries' manifests still name the same packages by URL, and SwiftPM
rejects a package reached through both. Setup, its uncommitted lock file and `RunScript.sh`:
`Documentations/Guides/LocalDependencies.md`.

**Embedded non-macOS products**: the app embeds three products that are not macOS — the Mac Catalyst
service (`RuntimeViewerCatalystService`), the Mac Catalyst helper (`RuntimeViewerCatalystHelper`) and the
iOS Simulator injection payload (`RuntimeViewerSimulatorServer`, in `RuntimeViewerServer.xcodeproj`).
**All three are ordinary target dependencies of the app**: building `RuntimeViewer macOS` — in the GUI,
through `RunScript.sh` or through `ArchiveScript.sh` — builds them in the app's configuration, and the
app's copy phases embed the built products. Nothing is built separately or staged, and a payload that
fails to build fails the app's build. This works only because each of those targets pins its own
platform; how, and which settings must not be touched: `Configurations/AGENTS.md`.

**Running the app from Xcode needs one Xcode default per machine**:
`defaults write com.apple.dt.Xcode DBGViewDebuggerInsertDylibOnDemand -bool YES`. Without it Xcode also
hands the app's macOS view-debugger library to the embedded Mac Catalyst service, which dies before
`main` (dyld: `Symbol not found: _OBJC_CLASS_$_ABPeoplePickerView`), and "My Mac (Mac Catalyst)" never
appears — with no error. Debug View Hierarchy keeps working: Xcode then loads the library when a
hierarchy is captured. The README's Troubleshooting section says the same for contributors. Background,
with the decompiled evidence: `Documentations/ResolvedIssues/2026-10-14-xcode-view-debugger-stops-catalyst-service.md`.

```bash
# Debug build + launch: configuration "Debug-arm64e", RuntimeViewer-Debug.xcworkspace, scheme
# "RuntimeViewer macOS" (builds the Catalyst products and the simulator payload as dependencies).
# The only working path for Debug-arm64e — the Xcode GUI fails to compile under
# iOSPackagesShouldBuildARM64e=true. Product: RuntimeViewer-Debug-arm64e.app under
# /Volumes/DerivedData/RuntimeViewer/Debug-arm64e when that volume exists (project-relative
# DerivedData otherwise).
./RunScript.sh
./RunScript.sh --no-launch         # build only
./RunScript.sh --update-packages   # refresh SPM pins before building
./RunScript.sh --dry-run           # print commands without running

# Start another instance of the Debug build on Xcode 26.6's own SourceEditor frameworks, to compare
# them with the reconstruction (needs System Integrity Protection off; RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md).
./LaunchWithXcodeSourceEditorScript.sh
./LaunchWithXcodeSourceEditorScript.sh --app <RuntimeViewer.app> --xcode <Xcode 26.6.app>

# Release build: archives the app (scheme "RuntimeViewer macOS"), notarizes, and optionally generates
# the appcast and uploads a GitHub Release. Omit the distribution flags for a local signed zip only.
# The version is MARKETING_VERSION in Configurations/Version.xcconfig, the one place a release bumps;
# the script checks --version-tag against it.
./ArchiveScript.sh
# Cut a full release (appcast + GitHub Release + commit docs/appcast.xml):
./ArchiveScript.sh --update-appcast --upload-to-github --commit-push --version-tag vX.Y.Z

# Build RuntimeViewerServer XCFramework (all platforms)
./BuildRuntimeViewerServerXCFramework.sh

# Build the jailbroken iOS variant (scheme "RuntimeViewer iOS Jailbroken") and package it as
# Products/Jailbroken/RuntimeViewerJailbroken.ipa, signed with the five entitlements it needs; the
# script reads them back off the .ipa and fails when one is missing. Goes through
# RuntimeViewer-Debug.xcworkspace, NOT RuntimeViewer.xcworkspace: only the Debug and Distribution
# workspaces set iOSPackagesShouldBuildARM64e, and without it the arm64e payload fails to link.
# Install it with something that keeps the entitlements on the binary (vphoned preserves them, a
# jailbreak installer grants them); Xcode re-signs and loses all five. Defaults to Debug, the
# configuration verified on a device.
./BuildJailbrokenIPAScript.sh
./BuildJailbrokenIPAScript.sh --configuration Release
./BuildJailbrokenIPAScript.sh --signer ldid  # vphone-cli | ldid | auto (default)
./BuildJailbrokenIPAScript.sh --no-build   # re-package the last build
./BuildJailbrokenIPAScript.sh --dry-run    # print commands without running

# Update the package pins of all three workspaces (RuntimeViewer, -Debug,
# -Distribution) to the newest versions the manifests allow. Use this instead of
# Xcode 27's "Update to Latest Package Versions", which resolves from git mirrors
# it never fetches. Xcode may stay open.
./UpdatePackagesScript.sh
./UpdatePackagesScript.sh --workspace Distribution   # one workspace (repeatable)
./UpdatePackagesScript.sh --clean                    # resolve from empty checkouts
./UpdatePackagesScript.sh --dry-run                  # print what would run
```

**Updating package pins**: `UpdatePackagesScript.sh` fetches every SwiftPM git mirror involved first, then
per workspace drops `Package.resolved` **and** `SourcePackages/workspace-state.json` (with only the lock
file gone, SwiftPM replays the pins recorded in the state file, so nothing updates) and resolves with
`xcodebuild -resolvePackageDependencies` in its own DerivedData, `/Volumes/DerivedData/RuntimeViewer/PackageUpdate`,
with `USING_LOCAL_DEPENDENCIES` forced off, because local checkouts drop out of a lock file. A failed or interrupted resolution puts the previous `Package.resolved` back. It ends by
listing the version changes and the changed lock files under version control; review and commit those —
the Distribution one is what release archives resolve against.

**From Xcode**: right-click `RuntimeViewerPackages` in the Project navigator and choose **UpdatePackages**,
a command plugin (`RuntimeViewerPackages/Plugins/UpdatePackages`, a target nothing depends on) that only
runs `UpdatePackagesScript.sh` and passes on the arguments typed into its sheet (such as
`--workspace Debug`); the plugin finds the script one level above the package. It needs Xcode's sandbox
switched off once — `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`,
then restart Xcode — because the script writes outside the plugin's work directory. That one key decides
both the manifest sandbox and the command plugins' sandbox, so **every** `Package.swift` and every command
plugin in every project runs unsandboxed from then on; `IDEPackageSupportDisablePluginExecutionSandbox`
covers build-tool plugins only (traced in `/Volumes/RE/Xcode/27.0/README.md`). With the sandbox on, the
command changes nothing and says what to do.

**Release archives keep Xcode 27's new package PIF builder off.** `ArchiveScript.sh` passes
`-IDEEnableNewPackagePIFBuilder=NO` to every `xcodebuild` that resolves or builds the package graph, and a
manual release archive outside the script needs the same flag. With the new builder every package builds
`arm64 arm64e arm64e.x1` only — x86_64 is dropped — and the universal `RuntimeViewerServicePlugin`
fails with `Unable to resolve module dependency`; which builder runs is otherwise a per-machine Xcode
default, so one Mac archives cleanly and another fails on the same commit. Background:
`Documentations/ResolvedIssues/2026-09-27-release-archive-packages-lost-x86-64.md`.

**Build Schemes**:
- `RuntimeViewer macOS` — main app; Debug-arm64e via `RunScript.sh`, Release archives via `ArchiveScript.sh`
- `RuntimeViewerCatalystHelper` — the Mac Catalyst helper on its own; building the main app builds
  it as a dependency, so this scheme is only for working on the helper. It no longer builds the
  plugin, which belongs to the app now; the Catalyst service has no scheme of its own
- `RuntimeViewerUsingAppKit` — plain Debug builds of the AppKit app target
- `RuntimeViewerCommandLineTool` — the copy of `runtime-viewer-cli` embedded in the app bundle; the app
  target depends on it, so building the app builds it too. It is named after the scheme, not after its
  product (`PRODUCT_NAME` is pinned to `runtime-viewer-cli`): the workspace also contains the SwiftPM
  package's executable product of that name, and two schemes called `runtime-viewer-cli` make
  `xcodebuild -scheme` pick one silently

### Testing

Package tests use swift-testing and run per package, through `queued-build`, with an agent-private
scratch path:

```bash
cd RuntimeViewerPackages
queued-build swift build --build-tests --scratch-path /Volumes/DerivedData/Agents.noindex/<agent>/SwiftPM/RuntimeViewerPackages
queued-build swift test --skip-build --scratch-path /Volumes/DerivedData/Agents.noindex/<agent>/SwiftPM/RuntimeViewerPackages --filter RuntimeViewerApplicationTests
```

How the suites stay off the user's real settings and bookmarks, and how they get an engine:
`RuntimeViewerPackages/Tests/AGENTS.md`.

</important>

<important if="you are changing build settings, a target, a configuration, a package dependency or its version floor, or anything else in the Xcode projects">

## Build Settings and the Tuist Development Workspace

**Build settings live in xcconfig files, not in the project files.** Every target of
`RuntimeViewerUsingAppKit.xcodeproj` (except the old `com.JH.RuntimeViewerService`), the
project level, and `RuntimeViewerServer` / `RuntimeViewerSimulatorServer` in
`RuntimeViewerServer.xcodeproj` set nothing in their project files; their settings are under
`Configurations/`, whose layout and per-target rules are in `Configurations/AGENTS.md`. Edit those files,
never Xcode's build settings editor or a target's General tab: both write a target-level value into the
project file, which outranks the xcconfig and which the Tuist project below does not see.
`./TuistScript.sh check` reports any such value.

**`RuntimeViewer-Tuist.xcworkspace` is a second, development-only way to build the macOS app.**
Tuist generates it from `Tuist.swift`, `Workspace.swift`, `Tuist/Package.swift` and
`RuntimeViewerUsingAppKit/Project.swift`; it builds the same targets from the same sources and the
same xcconfig files, with the four local packages as source and the third-party dependencies taken
from Tuist's local binary cache — all but MachOKitExtensions, MachOObjCSection, MachOSwiftSection
and swift-semantic-string, which change often alongside this repository and are built from source
too. **Releases, CI, `RunScript.sh`, `ArchiveScript.sh` and every
other script use the native projects only**, and the generated files are gitignored.

```bash
mise install                      # the Tuist mise.toml pins
./TuistScript.sh warm             # resolve, build the dependencies into the cache, generate
open RuntimeViewer-Tuist.xcworkspace
./TuistScript.sh build --configuration Debug-arm64e --launch   # like RunScript.sh
./TuistScript.sh check            # before committing a change to the native projects
```

- **A commit that changes the native projects' targets, dependencies, embedded products or
  settings updates the Tuist description in the same commit** — a local package's target list
  included, which `Tuist.swift` and `Tuist/ProjectDescriptionHelpers/LocalPackages.swift` repeat — and
  `./TuistScript.sh check` passes before it is committed; `check --build` also builds both workspaces
  and compares the two apps.
- **`Tuist.swift` also lists every target of those four third-party packages**
  (`sourceDependencyTargetNames`; the packages are `SOURCE_DEPENDENCIES` in `TuistScript.sh`). A pin
  move that adds or renames a target of theirs fails `check` until the list follows; a target left
  out goes into the binary cache.
- **`Tuist/Package.resolved` is not committed** (it is ignored). `./TuistScript.sh install` starts
  it from the Debug workspace's lock file every time, so it pins what the native lock files pin, and
  `UpdatePackagesScript.sh` runs that install after updating the Debug workspace. Install with the
  Xcode the native lock files were resolved with: some packages pick their manifest by Swift version.
- **Build the app with the `RuntimeViewer macOS` scheme only.** The simulator payload and the
  service plugin are built first by the scheme's fixed order, not as dependencies.
- **`--local-dependencies` builds the libraries `RuntimeViewer-Local.xcworkspace` takes from beside
  the checkout from those checkouts**, until `--remote-dependencies`; that mode has no package tests.

Agents run `TuistScript.sh` with `TUIST_SCRIPT_ROOT=/Volumes/DerivedData/Agents.noindex/<agent>/Tuist`
and through `queued-build`. What `check` compares, the Tuist workarounds behind the oddities in the
manifests, and the known differences from the native build: `Documentations/Guides/TuistDevelopment.md`.
Background: `Documentations/Evolutions/0053-tuist-coexistence.md`.

**Dependency floors**: UIFoundation is declared `from: "0.47.0"` with its `Settings` trait on (which
exposes `UIFoundationSettings` and `UIFoundationSettingsUI`). `0.47.0` is the first release with
`ScrollPocketView` and `NSView.box.titlebarBackdropGroupName` (`AppleInternal` trait), the stand-alone
scroll edge effects over the editor area's toolbar strip and behind each editor pane's tab bar, and the
backdrop group each pane's content gets. `0.43.0` brought `NSToolbar.box.preferredCenteredItemWidthRatio`,
which sizes the toolbar's activity capsule at 40 % of the toolbar's width as Xcode 26 does. `0.39.0`
brought the scroll pocket calls (`NSScrollView.box.registerScrollPocketContainer(_:on:)`,
`setScrollPocketStyle(_:on:)`, `NSView.barScrollPocketElementStyle` and the `_scrollPocketElementStyle`
declaration, `AppleInternal` trait) that `NavigatorScrollViewLayout` and the navigator bars use; the older features the app relies
on — `NSTableView.box.estimatesRowHeights`, `Label` mirroring `attributedStringValue` into its tooltip,
the synchronous `SettingsStore.save()`, `SettingsConfiguration`, `MainMenu` — all arrived before it.
`0.39.0` needs FrameworkToolbox `0.15.0` or later, which is why `RuntimeViewerCore` takes a FrameworkToolbox
floor instead of the exact pin it had; the comment there says what to check when FrameworkToolbox moves.
The floor is `from: "0.21.0"`, which `RuntimeViewerCommandLine` repeats: `0.21.0` is the first release with
`LogCategory(_:prefixesMessages:)`, which the log categories under *Logging* use. `0.16.0` was the first whose
`@FrameworkToolboxExtension` works out by itself whether the extended protocol is class-bound, and with an older
one `SwiftDeclaration.Definition`'s generated `box` setter assigns `self`, which crashes the compiler in SILGen.
SFSymbols is declared `from: "0.4.0"`, the first release with `nsuiImage` (it deprecated the misspelled
`nsuiImgae`). AppKitPlus-Release is declared `from: "0.19.0"`: `0.18.0` brought what the
sidebar's text-token filter fields need — a comparison type's `valuePrefix` / `valueSuffix`, no menu for a
token whose comparison the field does not offer, and the delegate's `filterTokenField(_:editingStringFor:)` —
and `NSNavigationPopoverController`, which the runtime source picker's list is; `0.19.0` stops a window that
showed a navigation popover from never being freed, and filters a long list in one quickly.
SwiftyXPC (the `MxIris-macOS-Library-Forks` fork) is declared `from: "0.5.106"`, the first release with
connections to an instance of an embedded service of their own (`ConnectionType.remoteServiceInstance`, which
each offline file's process is started with) and with listener handlers that reach connections accepted before
they were set.

</important>

<important if="you are touching an app icon, an .icon document, the icon build settings, or ArchiveScript.sh's icon check">

## App Icon

The app has four Icon Composer documents under `Resources/` — `AppIcon.icon`, `AppIconBeta.icon` and
their generated `Xcode26` variants — and the Mac Catalyst helper has a pair of its own in
`RuntimeViewerUsingAppKit/RuntimeViewerCatalystHelper/`. **Read `Resources/AGENTS.md` before changing any
of them, or the build settings that pick one**: a target-level value silently pins a single icon, `actool`
fails without an error, and Icon Composer's SVG pipeline ignores `stroke`.

</important>

<important if="you are committing, creating or merging a branch, opening a pull request, or deciding where a change belongs">

## Branching Model

- **`next`** — the development and release branch. Work starts on a short-lived
  feature branch cut from next and merges back into next when it is done; a pull
  request into next is optional. Documentation and small fixes may be committed
  to next directly. Releases are tagged on next (`vX.Y.Z`, pre-releases
  `vX.Y.Z-beta.N`); a pushed tag runs the `.github/workflows/release.yml` of the
  tagged commit, and a manual dispatch must pass `--ref next` or it runs main's
  older copy.
- **`main`** — carries the Sparkle feed and nothing else. GitHub Pages serves
  `docs/appcast.xml` from main's `/docs`, and the release workflow lands each
  release's appcast there through a pull request (main's ruleset rejects direct
  pushes). Its code is the 2.x line (last tag `v2.1.2`) and takes no other
  change: never branch from main, never deliver a change to it, never merge next
  into it. How a local release gets its appcast onto main:
  `Documentations/SparkleRelease.md`.
- **After every release, merge main into next.** A release appends its entry to
  the `docs/appcast.xml` of the commit it builds — next's copy — and the result
  replaces main's, so a next that lacks the previous release's appcast commit
  silently drops that entry from the live feed.
- **Before tagging**, build `RuntimeViewer-Distribution.xcworkspace`, not the
  Debug workspace: releases resolve that workspace's own committed
  `Package.resolved` (`ArchiveScript.sh` refreshes it only with
  `--update-packages`, which the release workflow never passes).

</important>

## Architecture

### Package Structure

The project uses three Swift Package Manager packages:

**RuntimeViewerCore** (`RuntimeViewerCore/`):
- `RuntimeViewerCore` — Runtime inspection engine using MachOObjCSection (ObjC) and MachOSwiftSection (Swift)
- `RuntimeViewerCommunication` — XPC/TCP-based IPC layer for cross-process inspection
- `RuntimeViewerInjection` — process injection as a RuntimeEngine command extension: the
  `RuntimeInjectionService` protocol, the wire types (`RuntimeProcess`,
  `RuntimeInjectionAvailability`, `RuntimePayloadRendezvous`), the five injection commands and
  the engine-side callers. `RuntimeViewerCore` holds none of it — injecting needs MachInjector on
  iOS and the privileged helper daemon on macOS, while Core also builds for watchOS, tvOS and
  visionOS. **Every process that serves an engine and links this module must call
  `RuntimeInjection.install()` once at its entry point**, including the ones that cannot inject;
  see *Injection commands* below
- `RuntimeViewerCrossReferences` — cross references (callers, callees and type references) read
  from arm64 machine code, as a RuntimeEngine command extension over MachOSwiftSection's
  `CrossReferenceAnalysis`: the wire types (`RuntimeCrossReferenceSubject`, `RuntimeCrossReference`,
  …), the three commands and the engine-side on-demand scan. Same obligation as the injection module:
  `RuntimeCrossReferences.install()` once at every serving process's entry point; see
  *Injection commands* below. Background: `Documentations/Evolutions/0056-cross-references.md`
- `RuntimeViewerService` — the privileged helper daemon's entry point: the helper server and the
  services it mounts. Here rather than in `RuntimeViewerPackages` because this package is the only one
  that declares swift-helper-service and swift-injection-peer: their version floors and local candidates
  live in this manifest alone, and `RuntimeViewerPackages`' `RuntimeViewerHelperClient` imports their
  client modules through `RuntimeViewerCommunication` without naming them
- `RuntimeViewerCoreObjC` — Objective-C interop utilities (internal target)

**RuntimeViewerPackages** (`RuntimeViewerPackages/`):
- `RuntimeViewerArchitectures` — MVVM + Coordinator pattern with RxSwift
- `RuntimeViewerAppCore` — ViewModels, cell ViewModels, routes, `DocumentState` and the application logic (Sidebar, Inspector, Content, Find, Theme, FilterEngine); testable, and no UI component appears in it (`RuntimeViewerPackages/Sources/AGENTS.md`)
- `RuntimeViewerAppUI` — the UI glue split out of the application layer: the adapters that set up AppKit and AppKitPlus controls, the jump bar's items, the toolbar activity presenter
- `RuntimeViewerApplication` — a facade that only re-exports the two above; the apps link this one product
- `RuntimeViewerUI` — AppKit UI components (MinimapView, StatefulOutlineView, skeleton effects)
- `RuntimeViewerServiceHelper` — Helper utilities
- `RuntimeViewerHelperClient` — Helper client for XPC communication
- `RuntimeViewerEngineManagement` — Engine discovery, lifecycle, sharing and mirroring (`RuntimeEngineManager`, `RuntimeProcessAttacher`); no AppKit / RxSwift so a headless process can link it alone
- `RuntimeViewerSettings` — RuntimeViewer's settings schema and dependency boundary over the single `UIFoundationSettings` store
- `RuntimeViewerSettingsUI` — RuntimeViewer's SwiftUI settings pages hosted by `UIFoundationSettingsUI`
- `RuntimeViewerCatalystExtensions` — Mac Catalyst support

**RuntimeViewerMCP** (`RuntimeViewerMCP/`) — MCP integration (macOS 15+ only):
- `RuntimeViewerMCPShared` — Shared protocols and transport types
- `RuntimeViewerMCPBridge` — Bridge server that runs inside the main app

**RuntimeViewerCommandLine** (`RuntimeViewerCommandLine/`) — the `runtime-viewer-cli` tool (macOS 15+ only), built with plain `swift build`; depends on `RuntimeViewerCore` and on the UI-free products of `RuntimeViewerPackages` (`RuntimeViewerEngineManagement`, `RuntimeViewerHelperClient`):
- `RuntimeViewerCommandLineInterface` — everything but `main.swift`: Codable command/result models, the length-prefixed JSON protocol over a Unix domain socket, `CommandExecutor` + `SourceResolving` (`EngineManagerSourceResolver` serves every source a `RuntimeEngineManager` holds and answers `sources` / `attach` / `detach`; `LocalSourceResolver` is the local-only fallback), the resident CLI host (`CommandLineHostServer`, spawned on demand, idle exit) and its client, `HostTakeover` / `HostRetirement` (the app replacing a standalone host, the client replacing an outdated one), renderers, and the swift-argument-parser commands. The app links this library too: `CommandLineHostController` makes the running app the host
- `runtime-viewer-cli` — one-line executable entry point
- Outside the package, `AgentPlugins/runtime-viewer/` is the agent plugin that teaches this tool. A change to the surface its skill describes (subcommands, flags, output, exit statuses, host behaviour) updates that skill in the same commit and bumps `version` in both of its plugin manifests — installed plugins only update when the version changes

### Application Targets

- `RuntimeViewerUsingAppKit` — Main macOS application (AppKit, document-based)
- `RuntimeViewerMCPServer` — MCP server executable (stdio-based, communicates with bridge via TCP)
- `RuntimeViewerServer` — XPC background service for inter-process communication
- `RuntimeViewerLocalService` — the plain XPC service (no mach service, no daemon) the app's
  "My Mac" engine runs in, embedded at `Contents/XPCServices/`. **The app process never dlopens or
  indexes an image itself.** `RuntimeEngine.local` decides where its work happens from the process's
  own `Info.plist`: the app's names the service it embeds under
  `RuntimeViewerLocalServiceBundleIdentifier`, so the app's `.local` forwards to it, while the
  service itself, the standalone CLI host, the Catalyst helper and service and the tests (no key) stay in
  process — launchd only finds an embedded service inside the calling process's own bundle, so the
  bundle is the configuration. The "Load Frameworks…" picker goes through `engine.loadImage(at:)`, not
  `Bundle.load`. A service crash costs the loaded images, not the app: the connection reattaches on its
  own and the engine only sees `.disconnected` then `.connected`. **All XPC-service code lives in a few
  named places** — `RuntimeViewerCommunication/Connections/XPCService/`
  (transport, `hello`, reattach, dedicated instances) plus the three `.xpcService` branches of
  `RuntimeCommunicator`; `RuntimeViewerCore/LocalService/` (this service's `Info.plist` key and
  credential, and the service-side host all three services run);
  `RuntimeViewerCore/Offline/RuntimeOfflineService.swift` and `RuntimeOfflineServiceHost.swift` (the
  offline service's key, credential and launch payload, and the host that opens the file the payload
  names); `RuntimeViewerCatalystExtensions/MacCatalystRuntimeService.swift` (the Catalyst service's key and
  credential); and the service entry points, `ServicePluginEntry` in `RuntimeViewerServicePlugin`. `RuntimeEngine` and
  `RuntimeEngineManager` know nothing about XPC — they hand an opaque credential on — keep it that
  way. **The service runs at the priority of the requests waiting on it**, and an app in App Nap
  donates none: about thirty seconds after the user switches away, work the app is waiting on slows
  down four- to tenfold. So long-running work the app waits on has to keep the app out of App Nap:
  each engine's background work holds a `BackgroundWorkProcessActivity`, a user-initiated activity
  held while `RuntimeEngineBackgroundWork.isWorkInProgress` is true (indexing batches, corpus builds,
  cross-reference preparations), and new work of that kind reports through that signal or holds an
  activity of its own. Background:
  `Documentations/Evolutions/0037-local-runtime-xpc-service.md`; the transport:
  `Documentations/CommunicationAndEngineArchitecture.md` §3.6; the priority:
  `Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`
- `RuntimeViewerCatalystService` — the Mac Catalyst XPC service the app's "My Mac (Mac Catalyst)"
  engine runs in, embedded at `Contents/XPCServices/`. The app's `Info.plist` names it under
  `RuntimeViewerCatalystServiceBundleIdentifier` (`MacCatalystRuntimeService` in
  `RuntimeViewerCatalystExtensions`), so the app's `.macCatalystClient` engine connects to it directly —
  no helper daemon, no handshake polling — and a crash is a reattach, not a lost engine. A process
  without the key — the standalone CLI host — keeps launching `RuntimeViewerCatalystHelper`. The App Nap
  rule above covers work on this engine too. The service has no "restarted" notification yet.
  Background: `Documentations/Evolutions/0051-catalyst-xpc-service.md`
- `RuntimeViewerOfflineService` — the XPC service each offline file (a Mach-O file, a bundle, a folder or
  a dyld shared cache read from disk) is read in, embedded at `Contents/XPCServices/`. Its `Info.plist` declares
  `_MultipleInstances`: an engine reading a file connects with `RuntimeOfflineService.credential(for:)`,
  `.xpcService(.dedicatedInstance(…))`, which starts an instance of its own, and the connection's first
  `hello` names the file — `RuntimeOfflineServiceHost` reads it and installs the engine's commands before
  answering. One instance serves one file to one client and exits when that client closes its connection
  (`setClientDepartureHandler(_:)`; a message it has no handler for is no departure). launchd never
  relaunches an instance, so a client whose instance went away reattaches behind a new connection. Its
  executable is a shell like the others below, and it carries no entitlement exception: it reads files
  as data and never loads one. The app opens a
  file's window before the instance has read it (`RuntimeEngineManager.startReading(_:)`), which is safe
  only because a `.file` engine made with `RuntimeEngine.init(source:…)` forwards from the moment it
  exists: until its connection is up a request fails instead of being answered from the app's own
  images. **A bundle's or a folder's images are listed from their headers and opened one at a time,
  when first asked for** (`RuntimeFileImageCatalog`, walked by `RuntimeDirectoryImageScanner`): an
  opened image holds a file descriptor for as long as it lives and a folder can hold thousands, so
  nothing there may open every image at once — a lookup across all of them, like the Objective-C class
  table, opens each only for as long as it reads it. Background:
  `Documentations/Evolutions/0069-offline-mode.md`, `Documentations/Evolutions/0077-offline-folders.md`
- `RuntimeViewerCatalystHelper` — the Mac Catalyst helper app the standalone CLI host opens through
  the helper daemon and that connects back through it
- `RuntimeViewerServicePlugin` — the code four executables run. **The Catalyst helper and the
  Catalyst, local and offline services are shells**: each only makes its process what it has to be (a
  Catalyst app, a Catalyst XPC service, a macOS XPC service) and loads this macOS bundle from the
  app's `Contents/PlugIns` (`ServicePluginLoader`, compiled into every shell); the plugin does the
  work — `ServicePluginEntry`'s `launchCatalystHelper()`, `runCatalystService()`, `runLocalService()`
  and `runOfflineService()`. So the app ships one copy of RuntimeViewerCore for the four processes:
  dead stripping works inside one binary only, and a shell that linked a package would carry a copy of
  its own. **Changes to what a service does go into the plugin, and a shell links no package.** A
  shared dynamic RuntimeViewerCore was tried and does not work: Xcode turns every package target that
  two images of one process link statically into a dynamic framework, for every target and platform.
  Background: `Documentations/Evolutions/0079-shared-service-plugin.md`
- `RuntimeViewerCommandLineTool` — `runtime-viewer-cli` built as a target dependency of the app and
  embedded at `Contents/Applications/runtime-viewer-cli`, signed and notarized with the app. Its
  entitlements carry `disable-library-validation`, and its deployment target has to track the app's
  (15.0) — Xcode fills in the current SDK version, which would make the embedded tool refuse to
  launch on systems the app itself supports. **Any target that produces a product of its own sets
  `SKIP_INSTALL = YES`**: otherwise it installs itself into the archive (this tool into `usr/local/bin`),
  the archive stops being an app archive, and the Developer ID export fails with
  `expected one {} but found developer-id`; `ArchiveScript.sh` fails right after archiving and names the
  stray files
- `RuntimeViewerUsingUIKit` — iOS variant (secondary)

### Key Architectural Patterns

- **Document-Based App**: NSDocument architecture; each document creates its own `DocumentState` instance
- **Engine work is shared by the documents on the engine**: each engine has one background indexing
  coordinator, one Find corpus coordinator and one cross-reference preparation coordinator, held by
  every document on it (`RuntimeEngineBackgroundWork`, handed out per engine by
  `RuntimeEngineBackgroundWorkRegistry`), so the windows on one engine show one Report — the same
  running work, the same history; the work also says once for all of them whether anything is in
  progress, and holds the App Nap activity. A document holds its part through
  `DocumentState.runtimeEngineSession`, a `RuntimeEngineSession` whose engine and work never change:
  **follow `$runtimeEngineSession` and take the work from the session it delivers** — never pair the
  engine with work read some other way, the ordering trap the session exists to remove.
  `runtimeEngine` only forwards `runtimeEngineSession.engine`. A document joins only through
  `startBackgroundWork()`, which `Document.makeWindowControllers` calls first; a new session is put in
  place then and when `.switchEngine` moves the document to another engine, the same one again when its
  engine starts over with something open, and a session without work (`backgroundWork == nil`) means
  show nothing and command nothing. A session also holds, as a borrower, the work of the engines its
  engine borrows shared cache images from (`borrowedBackgroundWorks`, a new session when they change):
  take an image's work from `backgroundWork(forImageAt:)`, never the engine's own for a borrowed image
  (`CommunicationAndEngineArchitecture.md` §7.4). A document that closes or moves away only leaves — nothing is
  cancelled while another document is on the engine — and the last one leaving cancels the engine's work
  and drops its Report; Cancel, Cancel All and Clear History speak for every window on the engine.
  **Never give a document indexing or corpus state of its own again.** A root already indexed starts no
  batch at all. **What the engine's process keeps — the Find corpora, the prepared cross references — is
  never dropped on its own**, not even when the last window leaves (that was tried and reverted: a window
  reopened at once rebuilt everything). The Report navigator's Searchable Interfaces and Cross
  References rows show its size and eject it (`ejectCorpora()`, `ejectPreparations()`), and it comes
  back when a search or a query needs it. Only a bounded part of it stays in memory (Settings › Search,
  64 MB each by default): a corpus its derived data holds is built whether it is in memory or not, and
  a search reads the missing ones back one image at a time; Keep Cross References Ready prepares images,
  the Always Index ones first, until its limit is full, evicting nothing, and leaves the rest to the
  queries that need them. **An image the user loads or has indexed goes through
  `DocumentState.recordingManualLoad(ofImageAt:_:)` or `indexImageForUser(at:)`**, which the Report lists
  under Manual Loading (`ManualImageLoadCoordinator`, part of the engine's work, and counted as work in
  progress): Load now, an image the sidebar or a jump bar opens before it is indexed, Load Frameworks…, a
  Find result or an object in an image not indexed yet. A new place that loads or indexes an image for the
  user does the same, and hands them only work that does something — an image answered from its index
  records nothing. Background:
  `Documentations/Evolutions/0055-engine-scoped-background-work.md`,
  `Documentations/Evolutions/0058-runtime-engine-session.md`,
  `Documentations/Evolutions/0065-engine-resident-memory.md`,
  `Documentations/Evolutions/0066-on-demand-corpora-and-cross-references.md`,
  `Documentations/ResolvedIssues/2026-10-16-second-document-disturbs-shared-indexing.md`
- **Editor panes**: the content area is `DocumentState.editorArea` — panes arranged by `EditorLayout`
  (Xcode's rules, two levels at most), each pane with its tabs, each tab with its own
  `NavigationHistory`, and the focused pane. `selectedRuntimeObject` and `cursorMember` only mirror the
  focused pane: follow them for what is on screen, `$editorArea` for anything about panes or tabs, and
  never `distinctUntilChanged()` the area raw — its equality compares objects by identity, so compare
  what you show (`TabBarSnapshot`). A `SelectionRoute` that names no tab or pane acts on the focused
  pane's active tab, so a pane's content focuses its pane (`.focusEditorPane`) before it opens anything;
  routes name tabs and panes by `DocumentTab.ID` / `EditorPane.ID`, never by index. `MainCoordinator.fanOut`
  hands the routes to `EditorAreaCoordinator`, one `ContentCoordinator` per pane; the pane the keyboard
  focus enters becomes the focused one. A content view controller names what takes the focus through
  `EditorPaneContent.focusableView`, never `preferredFirstResponder`, which AppKitPlus's navigation
  controller would hand the focus on every `set`. **A step of a tab's history is an object in a language
  or an image** (`NavigationEntry.Content`): an image chosen in a pane's jump bar (`.openImage`) shows the
  image page, which indexes it first; `selectedRuntimeObject` is `nil` on it, so read an entry's `object`
  as optional and switch over `content` where both matter. The jump bar never moves the sidebar
  (`.switchImage` is the sidebar's alone). Background: `Documentations/Evolutions/0076-editor-panes.md`,
  `Documentations/Evolutions/draft-editor-jump-bar.md`
- **MVVM-C (MVVM + Coordinator)**: Navigation via CocoaCoordinator (macOS) / XCoordinator (iOS)
- **Reactive Streams**: Heavy RxSwift usage for UI state and data flow
- **Dependency Injection**: Uses swift-dependencies for service injection
- **Multi-Process**: XPC services enable safe inspection of external processes, and the local
  runtime itself runs out of process in `RuntimeViewerLocalService.xpc`
- **MCP Bridge**: TCP bridge pattern — app hosts bridge server, external MCP server connects as client

### MCP Integration

The MCP feature enables LLM clients (e.g., Claude) to inspect runtime information via the Model Context Protocol.

**Architecture**:
```
RuntimeViewerApp (NSDocument)
    ↓ provides DocumentState
AppMCPBridgeWindowProvider
    ↓ bridge (TCP, length-prefixed JSON)
RuntimeViewerMCPBridge (library, in-process)
    ↓ TCP server
RuntimeViewerMCPServer (executable, stdio MCP)
    ↓ MCP protocol
LLM Client
```

- Bridge uses simple length-prefixed JSON over TCP (not RuntimeViewerCommunication framework)
- Port file: `~/Library/Application Support/RuntimeViewer/mcp-bridge-port`
- Bridge starts automatically in `AppDelegate.applicationDidFinishLaunching`
- MCP server entry: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/main.swift`

<important if="you are adding, reading or changing a setting, or touching the settings window or its SwiftUI pages">

### Settings Integration

- `RuntimeViewerSettings.Settings` is an `@Observable final class`. On macOS it conforms to
  `PersistentSettings` and owns the application's only `SettingsStore`. Code reads and writes it through
  `@Dependency(\.settings)` (`SettingsAccess`), which always reaches the current object in that store, so
  a captured `SettingsAccess` stays valid when `load()` replaces the model.
- **`Settings.accessPersistedValues()` must read every encoded top-level property** — update it whenever
  a persisted property is added. UIFoundation's store tracks that method to schedule persistence, while
  business observers keep top-level granularity (`theme` changes do not wake `transformer` listeners). An
  omission fails quietly: the property is still encoded whenever *another* property triggers a write, so
  only a session that changes nothing else loses the edit. `SettingsPersistenceTests` changes each
  property on its own and compares the covered list against the encoded payload's top-level keys, so a
  new property fails the suite until both places know about it.
- `SettingsLifecycleController` owns both ends of the lifecycle: call `load()` at launch before anything
  reads a value (resolving `@Dependency(\.settings)` does not load), and quit through
  `applicationShouldTerminate`, which calls the synchronous `flushSynchronously()` and returns
  `.terminateNow` so the write outruns the store's one-second auto-save debounce. **Never reply
  `.terminateLater` with the flush in a main-actor task**: when `terminate(_:)` is invoked from a
  main-queue block, as the helper-reinstall relaunch does, the app deadlocks — the controller's doc
  comment says why.
- SwiftUI pages use the local `AppSettings` typealias, which specializes
  `UIFoundationSettings.AppSettings` for RuntimeViewer's schema. The settings window passes
  `sidebarIconSize: 15` through the top-level `SettingsConfiguration` (the pre-migration glyph size) and
  restores its own frame: do not add a `center()` call, which would discard the position the user chose.
- Keep the persisted location compatible with existing releases:
  `~/Library/Application Support/RuntimeViewer[-Debug]/settings.json`.
- UIFoundation's Settings API is macOS-only, so `SettingsAccess` keeps an in-memory `Settings` on the
  other platforms and its `load()` / `flushSynchronously()` are no-ops there — harmless only because
  nothing off macOS writes a setting. Adding a settings UI to another platform means giving it real
  storage first, or the edits will vanish silently.
- Settings › Developer is the home for switches that exist to exercise the app while developing it. The
  page is registered under `#if DEBUG` only; its branch, `Settings.developer`, is persisted like any
  other (so it is in `accessPersistedValues()` and in `SettingsPersistenceTests`' coverage list).
  `Settings.Developer.isEnabled` is a master switch: consumers read an `effective…` property that already
  returns the inert value while the switch is off — never the raw option — so turning it off disables
  everything without losing the configured values. Add new options the same way. The first is
  `contentLoadingDelay`, which `ContentTextViewModel`'s default interface provider waits out ahead of the
  interface cache so the content loading plate can be brought up on demand.

</important>

## Development Guidelines

When adding new features, you **MUST** follow these rules:

1. **UI Framework**: AppKit for all UI. SwiftUI only in the Settings pages, whose window, sidebar,
   navigation, forms, bindings and persistence come from UIFoundation's Settings products
2. **Architecture**: MVVM-C — AppKit views and ViewControllers, RxSwift ViewModels, Coordinators for
   navigation; every ViewController has a ViewModel. The rules are in `RuntimeViewerUsingAppKit/AGENTS.md`
3. **Reactive**: Use RxSwift for data binding and event handling
4. **Swift Language Mode**: All packages use `swiftLanguageModes: [.v5]`
5. **Singletons go through `@Dependency`** — see *Singletons & Dependency Injection* under Code Style
6. **AppDelegate stays thin**: every non-trivial lifecycle responsibility is its own `@MainActor`
   controller class in `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/`;
   `RuntimeViewerUsingAppKit/AGENTS.md` says what AppDelegate may and may not contain
7. **Single-object interface fetches go through the document's interface cache**: fetch one object's interface via `documentState.interfaceCache.interface(for:options:)` with `ViewModel.currentMergedGenerationOptions` as the options — never bare `appDefaults.options` and never `runtimeEngine.interface(...)` directly — so cache keys line up with the content pane and exported text matches what it displays. Bulk consumers (interface export, MCP tools) deliberately bypass the cache and call the engine directly; do not route them through it. See `Documentations/Plans/2026-08-04-navigation-interface-cache.md`.
8. **A RuntimeEngine command that is not Core's own goes in its own module, not into Core**:
   declare its short name in `extension RuntimeEngine.CommandName` (keeping Core's namespace
   prefix, which is the wire contract), declare the `RuntimeEngineCommand` conformers under that
   module's own namespace, and install them from
   `RuntimeEngine.addCommandExtension(named:install:)`. Nothing
   in `RuntimeViewerCore` changes. `RuntimeViewerInjection` is the reference implementation; see
   *Injection commands* below for the one obligation this puts on every process. Like Core's own,
   the command declares how an engine borrowing shared cache images routes it
   (`RuntimeViewerCore/Sources/AGENTS.md`).
9. **A new `RuntimeObject.Properties` flag gets a row in the sidebar's Filter Scope**: declare it as
   a new case of `RuntimeObject.Properties.Flag` with the next bit position — the positions are wire
   format, so never renumber or reuse one — and build its static from that case, never from
   `init(rawValue:)`. `RuntimeObjectScope.Property.rows(filtering:)` switches over `Flag`
   exhaustively, so the build fails until the flag has a row: a new `Property` case, with its title
   and tooltip in `SidebarRuntimeObjectScopeViewController`, or an existing case when the flag is
   another face of the same thing (`isSwiftClass` and `isObjCClass` share `bridgedSwiftClass`,
   `isSwiftProtocol` and `isObjCProtocol` share `bridgedSwiftProtocol`). A flag belongs to at least
   one row, and to more than one when two rows overlap: `isSwiftClass` and `isSwiftProtocol` are
   also in `swiftDefined`, which takes the Objective-C entries of Swift-defined classes and
   protocols and leaves their Swift entries alone. **A `Property` case's raw value is stored**: the
   scope of every image is remembered per engine and image (`RuntimeObjectScopeMemory`, in
   `AppDefaults.runtimeObjectScopesByEngineAndImagePath`), so never rename a raw value of
   `Property` or `PropertyState` — a remembered scope would quietly drop that constraint.
   Background: `Documentations/Evolutions/0049-scope-filter-all-object-properties.md`, for
   `swiftDefined` `Documentations/Evolutions/0062-swift-defined-objc-protocol-mark-and-filter.md`,
   for the protocol pair `Documentations/Evolutions/0063-swift-declared-objc-protocols-in-swift-list.md`,
   and for the memory `Documentations/Evolutions/0085-filter-scope-memory.md`.

## Injection commands

The five injection commands (`injectionCapability`, `processList`, `applicationIcons`,
`injectIntoProcess`, `stopKeepingProcessAwake`) live in `RuntimeViewerInjection`, not in
`RuntimeViewerCore`, and are installed into the engine command table at runtime.

**Every process that serves a `RuntimeEngine` and links `RuntimeViewerInjection` must call
`RuntimeInjection.install()` exactly once at its entry point, before any engine connects** —
including the processes that cannot inject anything. The rule has no exceptions to reason about:
*linked it ⇒ call it*. The eleven places that do, today:

| Process | Where |
|---------|-------|
| macOS app | `AppDelegate.main()` |
| Local XPC service | `ServicePluginEntry.runLocalService()` |
| Offline XPC service | `ServicePluginEntry.runOfflineService()` |
| Mac Catalyst service | `ServicePluginEntry.runCatalystService()` |
| Mac Catalyst helper | `ServicePluginEntry.launchCatalystHelper()` |
| `runtime-viewer-cli` (both entry points) | `RuntimeViewerCommandLineMain.main()` |
| iOS / visionOS / jailbroken iOS apps | `InjectionServiceRegistrar.registerIfAvailable()` |
| Injected payload (`RuntimeViewerServer` / `RuntimeViewerMobileServer`) | `RuntimeViewerServer.main()` |

The offline service (`RuntimeViewerOfflineService`) makes both calls only because the service plugin
it runs links both modules. Nothing asks it: an engine reading a file (`.file` source) answers the injection capability query and every cross-reference command itself, without
dispatching (`RuntimeEngine+Injection.swift`, `RuntimeEngine+CrossReferences.swift`) — a file has no
processes to inject into, and its images are never mapped into a process for the scan to read. Over XPC
a command the serving process has no handler for is dropped, not answered, so an offline engine that did
ask would never learn the command is unsupported.

**Forgetting the call is not a compile error.** Handlers are installed as a connection is set up,
so a process that never registers simply has no handler for the capability query — and a dispatch
that fails is indistinguishable, to a host, from a peer built before these commands existed. The
symptom is a device running the correct variant being reported as unanswerable, with the injection
entry point silently disabled. `RuntimeEngine.addCommandExtension` logs an `.error` for a
registration that arrives after the first connection, and the registrar logs a `.fault` for a
duplicate wire name; those two log lines are the only trail this failure leaves.

`RuntimeInjection.install(service:)` takes this machine's `RuntimeInjectionService` when it has
one — only the jailbroken iOS variant does; macOS injects through the privileged helper daemon
instead. Passing `nil` never clears a service already recorded, so the order of two calls in one
process does not matter.

**The cross-reference commands follow the same rule.** `crossReferenceCallees`,
`crossReferenceCallers` and `crossReferenceTypeReferences` live in `RuntimeViewerCrossReferences`,
and every place in the table above
calls `RuntimeCrossReferences.install()` right after `RuntimeInjection.install()` — the iOS apps in
their `AppDelegate`, right after `InjectionServiceRegistrar.registerIfAvailable()`. Skipping it
fails the same silent way: the engine has no handler, and a host cannot tell it from an older
peer. A new process that serves an engine links both modules and makes both calls. The commands
run in the process that serves the engine, because the scan reads that process's own images and
the shared cache it maps: the local service answers for "My Mac", an injected payload for
the process it was injected into.

## Derived data

The Find corpora of the shared cache's images are kept on disk under
`~/Library/Caches/<app bundle identifier>/DerivedData`, filed by system (platform, version, build, shared cache
UUID) and by producer (the in-memory `LC_UUID`s of the image holding RuntimeViewerCore and of its dependencies
outside the shared cache), so a launch on the same system with the same code reads a corpus instead of printing
it again. Code: `RuntimeViewerCore/Sources/RuntimeViewerCore/DerivedDataStorage/`; proposal:
`Documentations/Evolutions/0061-derived-data.md`; **read `Documentations/DerivedData.md` before changing that
code or the corpus store's read phase** — it says why each part has the shape it has.

- **Only the two service processes read, write and clean it up.** `ServicePluginEntry.runLocalService()`
  and `ServicePluginEntry.runCatalystService()` call `RuntimeDerivedData.enableInThisProcess()` before any engine exists.
  Every other process leaves it off — the app itself (its Bonjour server engine answers commands in process), the
  command-line host, the Catalyst helper application, an injected payload, a test — and the app only measures
  and deletes it (`RuntimeDerivedDataMaintenance`). Leaving the call out fails quietly: that process just goes
  without derived data. **The offline service is the third**, with a switch of its own,
  `RuntimeDerivedData.enableForOfflineEngineInThisProcess()`: its engine reads a cache from disk, so its store
  (`RuntimeDerivedData.offlineStore(for:isSharedCacheImage:)`) is keyed by that cache — an `Offline-<platform>-<version>-<UUID>`
  system directory, or this Mac's when the file is paired with this Mac's cache — keeps only that cache's images
  as the engine's catalog names them, and never cleans up. The two local services' cleanup skips `Offline-`
  directories; only Delete Derived Data removes them.
- **Only images of the dyld shared cache**, whose contents the system identity names; a store does nothing for
  any other image.
- **A new kind of derived data goes through `RuntimeDerivedDataStore`**, with a `RuntimeDerivedDataKind` and a
  variant naming everything else its contents depend on (for the corpus: the Transformer digest and the member
  order), and its reader checks whatever a later reader would trap on before making a value of it, as
  `RuntimeInterfaceCorpusSnapshot` does. A library's own cache takes its directory from
  `imageDirectory(forImageAt:)`.
- **No test reaches the real location**: `RuntimeViewerCore/Tests/AGENTS.md`.

## SourceEditor Module

<important if="you are touching the SourceEditor module: the RuntimeViewerSourceEditorBridge framework, RuntimeViewerSourceEditorBridgeTests, SourceEditorBridgeProvider, SourceEditorFrameworks, FetchSourceEditorScript.sh, UpdateSourceEditorScript.sh, the Embed SourceEditor Frameworks phase, ContentSourceEditorViewController or SourceEditorThemeConversion">

Everything that drives the `SourceEditor` framework family: the `RuntimeViewerSourceEditorBridge`
framework, `RuntimeViewerSourceEditorBridgeTests`, `SourceEditorBridgeProvider`,
`SourceEditorFrameworks`, `ContentSourceEditorViewController`, and `SourceEditorThemeConversion`.
The app links the bridge framework and calls it directly; in official builds the bridge links the
reconstruction released in the private `Mx-Iris/SourceEditor` repository — `FetchSourceEditorScript.sh`
downloads the release pinned in `RuntimeViewerPrecompiledLibraries/SourceEditor/PinnedRelease.txt`
and the app's Embed SourceEditor Frameworks phase copies it in; `UpdateSourceEditorScript.sh` moves
the pin to another release. Any other build, and the Intel slice
of a universal one, compiles the bridge without it (`#if arch(arm64) && canImport(SourceEditor)`) and
shows interfaces in the built-in `NSTextView`. Nothing is loaded at run time, and nothing comes from
an installed Xcode.

**Hard precondition: read the reconstruction's sources, never infer.** The frameworks are our own
reconstruction, so a bug or a feature here starts from its sources: the `Mx-Iris/SourceEditor` checkout at
`/Volumes/Repositories/Private/Personal/Library/macOS/SourceEditor` (both Macs), read at the tag
`PinnedRelease.txt` names — `git -C <checkout> show <version>:<path>`, never `main`, and never a checkout
or an edit there. What the framework itself lacks is a change to that repository, not a workaround here.
RuntimeViewer's dump of Xcode 26.6 (`/Volumes/RE/SourceEditor/Xcode/26.6/`) and the original binaries are
for questions about Xcode's original only. **If what the question needs is not there, stop and ask for
it — say what is missing and what question it was going to answer. Do not proceed on inference**, and
never infer behavior from a symbol's or protocol's name, from what the equivalent AppKit class does, or
from what would make sense. How the module is built, how to establish a fact and where findings go:
`RuntimeViewerPrecompiledLibraries/SourceEditor/AGENTS.md` — read it before the first change.

</important>

## Code Style

### Naming Conventions

- **ViewController** classes must always end with `ViewController` suffix (e.g., `MCPStatusPopoverViewController`, NOT `MCPStatusPopoverController`)
- **ViewModel** classes must always end with `ViewModel` suffix (e.g., `MCPStatusPopoverViewModel`)
- **`layout` and `setup` are one word** in identifiers: `layoutSegmentedControlBar()`, `layoutAndDisplay()`, `setupBindings(for:)` — NOT `layOutSegmentedControlBar()` or `setUpBindings(for:)`. Only an override of a framework method keeps the framework's spelling (XCTest's `setUp()`)

### Access Control

- All members should be `private` by default; only widen the access level when external access is actually needed
- ViewModel `@RxObserved` state properties: `@RxObserved private(set) var`
- ViewController relays: `private let xxxRelay = PublishRelay<Void>()`
- ViewController views: `private let xxxLabel = Label()`

### Singletons & Dependency Injection

**每个项目 singleton 都必须隐藏在 `@Dependency` 后面，没有例外。** 标准写法见
`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppearanceController.swift`。

- `static let shared` **始终**使用 `fileprivate`（同文件中的 macro expansion 可以访问它，其他文件不能），绝不使用 `public` 或无修饰的 `static let`。禁止在定义文件外调用 `Foo.shared.bar()`，也不为了够到 `Foo.shared` 而 import 一个 module。
- 用 `extension DependencyValues` 里的 `@DependencyEntry` 生成 key 与 accessor，不要手写 `DependencyKey` enum 与 `get` / `set`。生成的 key 是 `nonisolated`，所以 `@MainActor` singleton 写 `@DependencyEntry(liveValue: MainActor.assumeIsolated { MyService.shared })`，且只允许在既有的 main-actor 调用路径中首次解析；非 `@MainActor` singleton 直接写 `@DependencyEntry(liveValue: MyService.shared)`。通常只写属性类型，让默认 test behavior 保持不变；确实需要时才加默认 test value 或 `previewValue:`。
- **唯一例外：接口在 `RuntimeViewerAppCore`、真实实现只能放在 `RuntimeViewerAppUI` 的依赖**（现在是 `appRouter`、`runtimeEngineIconProviding`、`runtimeObjectIconRendering`），照 swift-dependencies 文档「Separating interface and implementation」手写：AppCore 声明一个遵循 `TestDependencyKey`、只给 `testValue` 的 `package enum XxxKey` 和 `DependencyValues` 访问器（`get { self[XxxKey.self] }`），AppUI 在真实实现的文件里补 `extension XxxKey: DependencyKey` 与 `liveValue`。测试值要么被调用就记 issue，要么是不碰系统的替身。`CrossLayerDependencyTests` 核对每个这样的 key 在链接 AppUI 之后都有 live 值：新加一个，就加进它的清单。只限这一类，其余依赖照旧用 `@DependencyEntry`。
- key path 与类型同名、首字母小写（`MyService` → `\.myService`，`HelperServiceManager` → `\.helperServiceManager`）；`DependencyValues` 属性的访问级别与实际使用范围一致：跨 module 用 `public`，否则用 `package` 或 internal。调用方一律 `@Dependency(\.myService) private var myService`。
- **非隔离的类型（普通 class、actor、`nonisolated` 成员）不要用存储属性 `@Dependency` 持有 `@MainActor` 依赖。** 存储属性在哪个线程被读，就在哪个线程解析；只要那是进程里第一次读，`MainActor.assumeIsolated` 就会让进程中止，而「别处已经先在主线程取过」只是启动顺序的巧合——`15ed432a` 修过 `\.settings` 的一处，2026-10-14 又在 `RuntimeInjectClient` / `RuntimeHelperClient` 上崩了一次（`Documentations/ResolvedIssues/2026-10-14-helper-service-manager-resolved-off-main-actor.md`）。改成 `@MainActor` 的计算属性、在 getter 里声明 `@Dependency`（参照 `RuntimeInjectClient.helperServiceManager`）：每个读都先跳到主线程，新调用点漏了 `await` 编译不过；跳转留在同一个任务里，`withDependencies` 的覆盖照常生效。
- 有限例外：enclosing type 已经是 `private` / `fileprivate`（例如 file-scoped helper `EmptyRouteTransitionContext`）时保留 `static let shared`，额外加 `fileprivate` 会触发 redundant-modifier warning；Apple SDK singleton（`NSApplication.shared`、`NSWorkspace.shared`、`NSDocumentController.shared`、`UserDefaults.standard`、`FileManager.default` 等）不属于项目 singleton，直接使用。

### RxSwift Subscription Style

**Always use the trailing-closure variants** — `.emitOnNext { }`, `.driveOnNext { }`,
`.subscribeOnNext { }` and their `…MainActor` forms (`.emitOnNextMainActor { }`, …) — never the label
syntax `.emit(onNext:)` / `.drive(onNext:)` / `.subscribe(onNext:)`. For direct binding without closure
logic, `.drive()` / `.bind(to:)` are fine: `output.imageName.drive(label.rx.stringValue)`.

### Closures & Self Capture

- **Always** use `guard let self else { return }` after `[weak self]` (NOT `strongSelf`, NOT `if let self`).
- **Never `[unowned self]` in any closure that can outlive the ViewModel** — which in practice means
  every Rx operator closure and every async closure. `Observable.async` / async `flatMapLatest` run their
  body inside a `Task`; disposal only *cooperatively* cancels that Task, so the closure can still execute
  after `deinit` and the unowned load aborts in `swift_abortRetainUnowned`. ViewModels are torn down
  constantly (every selection rebind, tab switch, tab close), so this is a crash in normal navigation,
  not an edge case. When the body only needs document-scoped services, capture the properties, not
  `self` (`[documentState = self.documentState, _commonLoading = self._commonLoading]`); when it
  genuinely needs `self` (e.g. `#log`, which expands to `Self.logger`), use `[weak self]` +
  `guard let self` with an early-return value.

### Logging

Never start a `#log` message with a hand-written `[Tag]`. Log to a category declared with
`LogCategory("Tag", prefixesMessages: true)`, which puts `[Tag] ` in front by itself —
`#log(.debug, category: .engineMirroring, "…")` — and declare it in a `private extension LogCategory` at
the end of the file that logs to it. The line then goes to that os_log category, not the type's.

### Platform Requirements

- Swift 6.2, Xcode 15+
- RuntimeViewerCore: macOS 10.15+, iOS 13+, macCatalyst 13+, watchOS 6+, tvOS 13+, visionOS 1+
- RuntimeViewerPackages: macOS 15+, iOS 18+, macCatalyst 18+, tvOS 18+, visionOS 2+
- RuntimeViewerMCP: macOS 15+

## Documentation

- Index of every document: `Documentations/README.md`; a new or renamed document gets its row there
- Evolution proposals: `Documentations/Evolutions/`; bug write-ups: `Documentations/ResolvedIssues/`
- Design documents and implementation plans from before the proposal system: `Documentations/Plans/`

## Key Source Locations

- Main app entry: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift` (`AppDelegate` is itself `@main`; `static func main()` runs first, then the lifecycle callbacks)
- Main menu: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/MainMenuController.swift`
- Document model: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/Document.swift`
- Coordinator/navigation: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`
- Runtime engine: `RuntimeViewerCore/Sources/RuntimeViewerCore/Engine/RuntimeEngine.swift`
- Engine manager: `RuntimeViewerPackages/Sources/RuntimeViewerEngineManagement/RuntimeEngineManager.swift`
- Document state: `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/DocumentState.swift`
- Editor panes: the model in `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/EditorArea/`, the views
  and their coordinator in `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/EditorArea/`
- ViewModels: `RuntimeViewerPackages/Sources/RuntimeViewerAppCore/`; the UI glue they are bound through: `RuntimeViewerPackages/Sources/RuntimeViewerAppUI/`
- MCP bridge window provider: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppMCPBridgeWindowProvider.swift`
- MCP server: `RuntimeViewerUsingAppKit/RuntimeViewerMCPServer/`
- MCP bridge: `RuntimeViewerMCP/Sources/RuntimeViewerMCPBridge/`
- Command-line tool: `RuntimeViewerCommandLine/Sources/RuntimeViewerCommandLineInterface/` (usage guide: `Documentations/Guides/CommandLineInterface.md`)
