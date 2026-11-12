# AGENTS.md — the SourceEditor module

Everything that drives the `SourceEditor` framework family, which official builds link directly as
the reconstruction released in the private `Mx-Iris/SourceEditor` repository:

- the `RuntimeViewerSourceEditorBridge` framework (`RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/`),
  which the app links and calls directly, and the rest of the content pane's SourceEditor code in the
  app target's `Content/` — `SourceEditorBridgeProvider`, `ContentSourceEditorViewController`,
  `SourceEditorThemeConversion` and the other `SourceEditor*` files;
- `RuntimeViewerSourceEditorBridgeTests`, which links the bridge framework;
- `SourceEditorFrameworks` in `RuntimeViewerSettings`;
- the build plumbing: `FetchSourceEditorScript.sh`, `UpdateSourceEditorScript.sh`, `PinnedRelease.txt`
  beside this file, and the app's Embed SourceEditor Frameworks phase (`RuntimeViewerUsingAppKit/BuildPhases/`);
- `LaunchWithXcodeSourceEditorScript.sh`, which starts a Debug build on Xcode 26.6's originals (see
  *Running a Debug build on Xcode's original*).

These rules cover all of them, not only the files in this directory. They live here because the
app's folders are Xcode synchronized folders, where a file becomes a resource of the target. The
root `AGENTS.md` repeats the precondition and points here.

## How the module is built

- `FetchSourceEditorScript.sh` downloads the release `PinnedRelease.txt` names into `Frameworks/`
  beside this file (ignored by git), after checking every zip against its pinned SHA-256.
  `RunScript.sh` runs it before it builds and `TuistScript.sh` before it generates or builds, both
  carrying on without the frameworks when it cannot download them; `ArchiveScript.sh` stops instead.
- The bridge framework and its tests have `Frameworks/` on their framework search path. Where it
  holds the frameworks, the bridge compiles and links them; where it does not, everything under
  `#if arch(arm64) && canImport(SourceEditor)` compiles out, `SourceEditorBridgeFactory.isAvailable`
  is `false`, and the app shows interfaces in the built-in `NSTextView`.
- **Every guard is `#if arch(arm64) && canImport(SourceEditor)`, never `canImport` alone**, so the
  Intel half of a universal build compiles out the same way. The releases carry no x86_64 slice, but
  every framework has a Clang module map, so an x86_64 compile that can see them satisfies
  `canImport(SourceEditor)` and then fails at their generated `-Swift.h` headers ("unsupported Swift
  architecture"). Keeping them off the x86_64 search path is not enough: the bridge's Copy
  SourceEditor Frameworks to Products phase puts them in the products directory, which every target
  searches, so from the second build in a DerivedData on, x86_64 sees them anyway. The search path
  is still set for the arm64 slices only (`FRAMEWORK_SEARCH_PATHS[arch=arm64*]`). Debug-arm64e builds
  arm64 only; only a Release universal build, as `ArchiveScript.sh` makes, compiles that slice, and
  it fails only once the products directory holds the frameworks — so check a guard change with two
  Release builds in the same DerivedData.
- **The app must never load the SourceEditor modules.** Their headers declare AppKit's private
  `NSScrollViewDelegate`, and so do UIFoundation's (`UIFoundationAppleInternalObjC`), differently; a
  module that sees both fails to compile. So the app target does not have `Frameworks/` on its search
  path, the bridge imports the SourceEditor modules with `internal import`, and its public API — the
  `SourceEditorBridging` protocols and `SourceEditorBridgeFactory` — mentions none of their types.
- The Embed SourceEditor Frameworks phase copies the four frameworks into `Contents/Frameworks` and
  signs them. It fails the build when `Frameworks/` holds a download for another pin: the app would
  link one release and ship none.
- **Tests and debug runs must find the reconstruction before Xcode's copies.** Run from Xcode or under
  XCTest, dyld searches `DYLD_FRAMEWORK_PATH` before any rpath, and for tests Xcode puts its own
  `SharedFrameworks` on it — which holds Xcode's SourceEditor, SourceModel and SourceModelSupport.
  The bridge framework's Copy SourceEditor Frameworks to Products phase (the same script, given the
  products directory) puts the reconstruction in the products directory, which comes first. Setting
  `DYLD_FRAMEWORK_PATH` in the environment instead replaces Xcode's whole value, and then not even the
  bridge framework is found. A test run against Xcode's copies either fails to load — Xcode 27 lacks
  symbols the reconstruction exports — or, worse, passes against the wrong frameworks.
- Moving to another release: `./UpdateSourceEditorScript.sh [<version>]` (`--dry-run` shows the
  change first). Without a version it takes the newest release on the pinned release's line — the
  same major version, 26 or 27 — prereleases included, and never moves back: GitHub's own latest
  release leaves prereleases out, and taking it once moved a pin of `27.2.0-alpha.1` back to `26.6.6`
  (`Documentations/ResolvedIssues/2026-11-12-update-source-editor-moved-the-pin-back.md`). Moving to
  an older release or to another line takes the version. It writes the version and the four SHA-256
  values that release's own `Package.swift` gives into `PinnedRelease.txt`, downloads the release
  through `FetchSourceEditorScript.sh` — putting the pin file back when that fails — and prints the
  Breaking section of every release it moved across. Adapt the bridge to those changes, run
  `RuntimeViewerSourceEditorBridgeTests`, and commit `PinnedRelease.txt` together with them.

## Hard precondition: read the reconstruction's sources, never infer

The frameworks the app links are our own reconstruction, not Xcode's, and their sources answer how
they do a thing directly. **For a bug in this module or a feature it needs, read them before
anything else.** Every wrong answer this module has produced came from reasoning about what the
framework "must" do instead of reading what it does.

- **Where**: the checkout of `Mx-Iris/SourceEditor` at
  `/Volumes/Repositories/Private/Personal/Library/macOS/SourceEditor`, the same path on both Macs.
- **Which version**: the release the app links — the version in `PinnedRelease.txt`, which is a tag
  of that repository. Read it at the tag, `git -C <checkout> show <version>:<path>` and
  `git -C <checkout> grep <pattern> <version>`, not on `main`, which runs ahead of the pin; when the
  tag is missing, `git -C <checkout> fetch --tags`. Never check out, edit or commit in that checkout:
  it is where the reconstruction itself is worked on.
- **What is there**: every framework's sources, and its resources — the `.xclangspec` grammars and
  `Built-in Syntax Types.xcsynspec` (the theme's syntax keys and their hierarchy) in
  `SourceModel/Resources/LanguageSpecifications/`, the built-in `.xccolortheme`s in
  `SourceEditor/Resources/`. A method's comment names the address in Xcode 26.6 it rebuilds, which is
  what a claim taken from the sources cites.
- **What the framework itself lacks** — a fix, a hook, a feature — is a change to the SourceEditor
  repository, which reaches this one through a release and `UpdateSourceEditorScript.sh`; so is a
  place where the reconstruction and Xcode 26.6 disagree. Neither is something to work around here
  without saying so.

**If the checkout, or the tag of the pinned release, is not there, stop and ask for it — say what
is missing and what question it was going to answer. Do not proceed on inference.**

## When the question is about Xcode's original

Only a question about Xcode's own frameworks — whether the reconstruction matches the original, or
how the original does something the reconstruction does not have yet — needs the material the
reconstruction was rebuilt from. Then the same rule holds: when it is not on disk, stop and ask for
it.

1. **A RuntimeViewer dump of the frameworks** — `/Volumes/RE/SourceEditor/Xcode/<version>/`,
   one directory per framework, each holding **both** `ObjCHeaders/` and `SwiftInterfaces/`, of
   Xcode 26.6: the reconstruction rebuilds that version, and its release numbers say so (`26.6.N`).
   Releases of its `xcode-27` line (`27.M.N`, and prereleases such as `27.2.0-alpha.1`) are the
   same rebuild with the changes Xcode 27 made carried over one at a time, each recorded with its
   Xcode 27.2 addresses in the reconstruction's SourceNotes; for one of those, the original to
   compare with is Xcode 27.2's (`/Volumes/RE/SourceEditor/Xcode/27.2/`).

   **It has to be RuntimeViewer's own export, and both directories have to be there.** A dump from
   any other tool does not substitute, and neither does reading the binary with `nm` / `otool` /
   `class-dump`: what makes this module tractable is exactly what those do not print — protocol
   requirements carried *with their witness-table offsets*, enum cases *in declaration order* (a
   resilient enum's case indices come from it), a class's real superclass and specifically whether
   it is rooted at `NSObject`, struct field layouts, and the address of every method — which turns
   decompilation into a lookup instead of a search.

   One of the two directories missing counts as no dump: the Swift surface and the Objective-C
   surface answer different questions, and this module needs both — the framework's own types come
   from `SwiftInterfaces/`, while what it inherits from and which `@objc` methods its classes really
   carry come from `ObjCHeaders/`.
2. **The framework binaries** — the reconstruction the app links, in `Frameworks/` once
   `./FetchSourceEditorScript.sh` has run, and the Xcode 26.6 originals it rebuilds,
   `<Xcode 26.6>.app/Contents/SharedFrameworks/<Name>.framework/Versions/A/<Name>`.

## Running a Debug build on Xcode's original

`./LaunchWithXcodeSourceEditorScript.sh` starts another instance of a build — `RunScript.sh`'s, or the
one `--app` names — on Xcode 26.6's own frameworks, so that it can be compared side by side with an
instance on the reconstruction. Background: `Documentations/Evolutions/0075-xcode-source-editor-comparison.md`.

- **Why it works without changing the app.** Xcode 26.6's four frameworks depend only on each other and
  carry the reconstruction's install names, `@rpath/<Name>.framework/Versions/A/<Name>`. The script points
  `DYLD_FRAMEWORK_PATH`, which dyld searches before any rpath, at a directory of links to exactly those
  four — the whole `SharedFrameworks` would substitute every other framework found there by name — and
  the same app and bridge load Xcode's copies instead of the ones in `Contents/Frameworks`.
- **What it checks.** Before launching, that every symbol the bridge imports from the four, weak
  references aside, is exported by Xcode's copies, or dyld would stop the app at launch. After launching,
  which copies of the four the new instance mapped; it quits the instance when any of them is not Xcode's.
- **Where it works.** The app has the hardened runtime, and Apple documents that dyld then reads `DYLD_`
  variables only for an app with the `com.apple.security.cs.allow-dyld-environment-variables`
  entitlement, which no RuntimeViewer build carries. With System Integrity Protection off, as on both
  development Macs, dyld takes the variable anyway: on 2026-11-06 a hardened stand-in signed without
  `get-task-allow` or that entitlement loaded Xcode's four frameworks. So it works on a Mac with SIP off
  whatever the build, and — by Apple's documentation, not measured — on no Mac with SIP on.
- **Xcode 26.6 only.** On 2026-11-06 the bridge imported 225 symbols from the four, all exported by Xcode
  26.6; Xcode 27.2 lacked three — `SourceEditorView`'s conformance to `TextFindableDisplayable`, that
  protocol's `perform(_:)`, and the requirement `NodeTypeAdjuster.adjustNodeType(for:)`, whose signature 27
  changed. A bridge change that imports something Xcode 26.6 does not export makes the script refuse, and
  the comparison is lost until the reference is weak or goes.
- **Which copy an instance runs on** is in Settings › Developer (`SourceEditorFrameworks.loadedCopy`). Both
  instances read the same settings file, and the one started last takes over the command-line tool's host
  and the MCP bridge.
- A difference the comparison shows is a finding about the reconstruction: it goes to the SourceEditor
  repository, like anything else the framework gets wrong (*What the framework itself lacks*, above).

## Never infer behavior from

- a symbol's name, or a protocol's name — `SourceEditorViewMissingKeyBindings` sounds like a
  category of implementations and is in fact a protocol the framework declares and never
  implements;
- what the equivalent AppKit class does — `NSTextView` implements `delete:`, `cut:` and
  `copy:`; `NSResponder` and `NSView` implement none of them, and neither does `SourceEditorView`;
- what would "make sense" for the framework to do.

## How to establish a fact, cheapest first

1. **The framework's own resources.** Grammar and theme questions are answered outright by
   `*.xclangspec` / `*.xcsynspec`. Read those before anything else.
2. **The reconstruction's sources** at the pinned tag. "Does it call my hook, and under what
   condition", a default value, which layer draws what — read the method.
3. For Xcode's original only: **the dump** (signatures, layouts, requirement order, method
   addresses), then **decompilation** via the `idalib` MCP, opening the framework binary directly —
   the dump gives you the address, so go straight to it.
4. **A runtime probe.** The last word on "does this class actually respond to that selector". A
   test in `RuntimeViewerSourceEditorBridgeTests` links the frameworks the way the app does and can
   ask the Objective-C runtime directly:

   ```swift
   let viewClass: AnyClass = SourceEditorView.self
   class_getInstanceMethod(viewClass, Selector(("delete:")))   // nil ⇒ not implemented
   ```

Behavioral claims that reach the user or a document must name their evidence: the file and rule
for a grammar fact, the release, the method and the address its comment names for one read from
the reconstruction's sources, the symbol and address for a decompiled one, the probe's output for a
runtime one.

## Where the findings live

Framework behavior that cost effort to establish goes into the decision log of
`Documentations/Evolutions/0009-content-editor-engine-selection.md`, or into a
`Documentations/ResolvedIssues/` note when it was a bug hunt. Include the evidence, not just the
conclusion — the next task on this module starts by reading them.
