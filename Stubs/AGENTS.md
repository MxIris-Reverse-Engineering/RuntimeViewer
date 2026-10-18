# AGENTS.md — the SourceEditor module

Everything that drives Xcode's private `SourceEditor` framework family: these stubs, the
`RuntimeViewerSourceEditorBridge` bundle target (`RuntimeViewerUsingAppKit/RuntimeViewerSourceEditorBridge/`),
and, in the app target's `Content/`, `SourceEditorLoader`, `ContentSourceEditorViewController` and
`SourceEditorThemeConversion`. These rules cover all of them, not only the files in this directory —
they live here because the bridge's folder is an Xcode synchronized folder, where a file becomes a
resource of the target. The root `AGENTS.md` repeats the precondition and points here.

## Hard precondition: no dump, no binaries, no work

**Before touching this module, confirm the reference material is on disk. If it is not, stop and
ask for it — say what is missing and what question it was going to answer. Do not proceed on
inference.** This is not a preference. Every wrong answer this module has produced came from
reasoning about what the framework "must" do instead of reading what it does.

What has to be present:

1. **A RuntimeViewer dump of the frameworks** — `/Volumes/RE/SourceEditor/Xcode/<version>/`,
   one directory per framework, each holding **both** `ObjCHeaders/` and `SwiftInterfaces/`.

   **It has to be RuntimeViewer's own export, and both directories have to be there.** A dump
   from any other tool does not substitute, and neither does reading the binary with `nm` /
   `otool` / `class-dump`: what makes this module tractable is exactly what those do not print —
   protocol requirements carried *with their witness-table offsets* (a gap in the sequence tells
   you a requirement is missing from your stub), enum cases *in declaration order* (a resilient
   enum's case indices come from it), a class's real superclass and specifically whether it is
   rooted at `NSObject` (getting this wrong crashes at deallocation, nowhere near the cause),
   struct field layouts, and the address of every method — which turns decompilation into a
   lookup instead of a search. `Stubs/README.md` says the same thing from the stub-authoring
   side, and says it because deriving these facts from the symbol table took an afternoon and
   got some of them wrong.

   One of the two directories missing counts as no dump: the Swift surface and the
   Objective-C surface answer different questions, and this module needs both — the framework's
   own types come from `SwiftInterfaces/`, while what it inherits from and which `@objc` methods
   its classes really carry come from `ObjCHeaders/`.

   The dump also has to be of the Xcode version being targeted; see below.
2. **The framework binaries** — `/Applications/Xcode.app/Contents/SharedFrameworks/<Name>.framework/Versions/A/<Name>`
   — for decompilation and for runtime probes.
3. **The framework resources**, whenever the question touches parsing, tokenization or theming:
   `SourceModel.framework/Resources/LanguageSpecifications/` holds the `.xclangspec` grammars
   (plain text, readable directly) and `Built-in Syntax Types.xcsynspec`, which is where the
   theme's syntax keys and their hierarchy are defined.

The dump's Xcode version must match the Xcode the code will run against. Addresses move between
versions, and so do interfaces.

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
2. **The dump.** Signatures, layouts, requirement order, method addresses.
3. **Decompilation** via the `idalib` MCP, opening the framework binary directly. This is how
   you answer "does it call my hook, and under what condition" — the dump gives you the address,
   so go straight to it.
4. **A runtime probe.** The last word on "does this class actually respond to that selector".
   Load the frameworks the way the app does and ask the Objective-C runtime:

   ```swift
   // Same four frameworks and same fixed-point loop as SourceEditorLoader: their install names
   // are @rpath-relative and they depend on each other, so one that fails a pass succeeds a later one.
   let names = ["SourceEditor", "SourceModel", "SourceModelSupport", "_CodeCompletionFoundation"]
   // dlopen(path, RTLD_LAZY | RTLD_GLOBAL) each, repeating until a pass makes no progress
   let viewClass = NSClassFromString("_TtC12SourceEditor16SourceEditorView")
   class_getInstanceMethod(viewClass, Selector(("delete:")))   // nil ⇒ not implemented
   ```

Behavioral claims that reach the user or a document must name their evidence: the file and rule
for a grammar fact, the symbol and address for a decompiled one, the probe's output for a
runtime one.

## Writing the stub interfaces

`Stubs/README.md` is the procedure, and it is not optional reading — it covers `final` versus
plainly-declared members, protocol requirement order, and the superclass rule that crashes only
at deallocation when you get it wrong. Adding API means: edit the `.swiftinterface`, run
`Generate.sh --full`, link the bridge, write its new undefined symbols back into
`UsedSymbols.txt`, then re-run `Generate.sh` **without** `--full`. Check `git diff --stat`
before committing — the full `.tbd` files are 1.1 MB and must never land.

## Where the findings live

Framework behavior that cost effort to establish goes into the decision log of
`Documentations/Evolutions/0009-content-editor-engine-selection.md`, or into a
`Documentations/ResolvedIssues/` note when it was a bug hunt. Include the evidence, not just the
conclusion — the next task on this module starts by reading them.
