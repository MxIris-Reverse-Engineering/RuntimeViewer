# Stubs

Hand-written link stubs for the private Swift frameworks that ship inside Xcode
(`Xcode.app/Contents/SharedFrameworks/`). They exist so `RuntimeViewerSourceEditorBridge`
can be compiled and linked without Apple's binaries being present in this repository.

Nothing here is Apple-authored: each framework directory holds two text files.

```
SourceEditor.framework/
├── SourceEditor.tbd                            # exported symbol list (tapi stubify)
└── Modules/
    └── SourceEditor.swiftmodule/               # a directory, not a binary swiftmodule
        └── arm64-apple-macos.swiftinterface    # hand-written subset of the real module
```

The frameworks enable library evolution, so a `.swiftinterface` is all the compiler needs —
it compiles the interface into its module cache on demand. No binary `.swiftmodule` is
required, and no Apple binary is redistributed.

## Regenerating the `.tbd`

```sh
./Generate.sh                                     # uses the active Xcode
./Generate.sh /Applications/Xcode-beta.app        # or point at a specific one
```

## Editing the `.swiftinterface`

The interface is a *subset*: only what the bridge actually calls. Three rules decide how each
declaration must be written, and all three are mechanical — ask the binary, don't guess.

**1. `final` or not, decided by the exported symbol form.** A member reached through a
dispatch thunk is declared plainly; a member the framework exports only as a direct symbol
must be declared `final`, or the linker fails with `Undefined symbols: dispatch thunk of …`.
Do not guess — ask the binary:

```sh
printf '%s\n' SourceEditor.SourceEditorView.dataSource | ./AuditMembers.sh
```

**2. Protocol requirement order must match the witness table.** RuntimeViewer's own dumps
print protocol witness table offsets; they run `0x8, 0x10, 0x18, …` in witness-table order,
which is declaration order. Copy that order verbatim. **A gap in the offsets means a
requirement is missing from the interface** — that is a free completeness check, so use it
rather than eyeballing.

Without a dump to hand, the same order can be recovered from the binary: the requirements'
method descriptors are laid out contiguously in declaration order, so sorting them by address
gives it.

**3. A class's superclass must be right, specifically whether it is rooted at `NSObject`.**
This is the one that will waste an afternoon. A class wrongly declared as its own root
constructs fine, answers every call fine, and only crashes when it is **deallocated** — Swift
emits native release for a root class it believes it owns, while the real object needs the
Objective-C `dealloc` chain. The crash is a jump to a garbage address with no usable
backtrace, and an instance kept alive for the lifetime of the process hides it completely.

```sh
printf '%s\n' SourceEditor.SourceEditorGutter | ./AuditClasses.sh
```

| Verdict | Declaration |
|---|---|
| `OBJC` | `@objc public class X : ObjectiveC.NSObject { @objc override dynamic public init() … }` |
| `native` | `public class X { … }` |

In this framework `SourceEditorView`, `SourceEditorContentView` and `SourceEditorGutter` are
`NSObject`-rooted, while `SourceEditorTheme`, `SourceEditorDataSource` and
`SourceEditorLayoutManager` are native Swift classes.

**`@objc deinit` is not the signal here, and reading it as one sends you the wrong way.** On
Darwin every Swift class exposes its deinit as `dealloc`, so real `.swiftinterface` files print
`@objc deinit` on plenty of classes that inherit nothing — SwiftUI's are full of them.
Measured directly: adding `@objc deinit` to a wrongly-rooted class does not stop the crash,
and only correcting the superclass does.

Resilient enums are ordered too: case indices come from declaration order, so a partially
copied enum silently mismatches. `SourceEditorTokenType` is therefore declared with no cases
at all — values of it are only passed through, never matched on.
