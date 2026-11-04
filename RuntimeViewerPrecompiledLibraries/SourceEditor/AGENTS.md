# AGENTS.md — the SourceEditor module

Everything that drives the `SourceEditor` framework family, which official builds link directly as
the reconstruction released in the private `Mx-Iris/SourceEditor` repository:

- the `RuntimeViewerSourceEditorBridge` framework (`RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/`),
  which the app links and calls directly, and the rest of the content pane's SourceEditor code in the
  app target's `Content/` — `SourceEditorBridgeProvider`, `ContentSourceEditorViewController`,
  `SourceEditorThemeConversion` and the other `SourceEditor*` files;
- `RuntimeViewerSourceEditorBridgeTests`, which links the bridge framework;
- `SourceEditorFrameworks` in `RuntimeViewerSettings`;
- the build plumbing: `FetchSourceEditorScript.sh`, `PinnedRelease.txt` beside this file, and the
  app's Embed SourceEditor Frameworks phase (`RuntimeViewerUsingAppKit/BuildPhases/`).

These rules cover all of them, not only the files in this directory. They live here because the
app's folders are Xcode synchronized folders, where a file becomes a resource of the target. The
root `AGENTS.md` repeats the precondition and points here.

## How the module is built

- `FetchSourceEditorScript.sh` downloads the release `PinnedRelease.txt` names into `Frameworks/`
  beside this file (ignored by git), after checking every zip against its pinned SHA-256.
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
- Moving to another release: change the version and the four SHA-256 values in `PinnedRelease.txt`
  (each is the checksum that release's own `Package.swift` gives for the zip), then run
  `./FetchSourceEditorScript.sh`.

## Hard precondition: no dump, no binaries, no work

**Before touching this module, confirm the reference material is on disk. If it is not, stop and
ask for it — say what is missing and what question it was going to answer. Do not proceed on
inference.** This is not a preference. Every wrong answer this module has produced came from
reasoning about what the framework "must" do instead of reading what it does.

What has to be present:

1. **A RuntimeViewer dump of the frameworks** — `/Volumes/RE/SourceEditor/Xcode/<version>/`,
   one directory per framework, each holding **both** `ObjCHeaders/` and `SwiftInterfaces/`, of
   Xcode 26.6: the reconstruction rebuilds that version, and its release numbers say so (`26.6.N`).

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
3. **The framework resources**, whenever the question touches parsing, tokenization or theming:
   `SourceModel.framework/Resources/LanguageSpecifications/` holds the `.xclangspec` grammars
   (plain text, readable directly) and `Built-in Syntax Types.xcsynspec`, which is where the
   theme's syntax keys and their hierarchy are defined.

The reconstruction is meant to behave as Xcode 26.6 does, and its sources — the private SourceEditor
repository — answer how *it* does a thing directly. When it and the original disagree, that is a
finding for the SourceEditor repository, not something to work around here without saying so.

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
2. **The dump**, and for the reconstruction its sources. Signatures, layouts, requirement order,
   method addresses.
3. **Decompilation** via the `idalib` MCP, opening the framework binary directly. This is how
   you answer "does it call my hook, and under what condition" — the dump gives you the address,
   so go straight to it.
4. **A runtime probe.** The last word on "does this class actually respond to that selector". A
   test in `RuntimeViewerSourceEditorBridgeTests` links the frameworks the way the app does and can
   ask the Objective-C runtime directly:

   ```swift
   let viewClass: AnyClass = SourceEditorView.self
   class_getInstanceMethod(viewClass, Selector(("delete:")))   // nil ⇒ not implemented
   ```

Behavioral claims that reach the user or a document must name their evidence: the file and rule
for a grammar fact, the symbol and address for a decompiled one, the probe's output for a
runtime one.

## Where the findings live

Framework behavior that cost effort to establish goes into the decision log of
`Documentations/Evolutions/0009-content-editor-engine-selection.md`, or into a
`Documentations/ResolvedIssues/` note when it was a bug hunt. Include the evidence, not just the
conclusion — the next task on this module starts by reading them.
