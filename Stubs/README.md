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

The interface is a *subset*: only what the bridge actually calls. Two rules decide how each
member must be declared, and both are mechanical.

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

Resilient enums are ordered too: case indices come from declaration order, so a partially
copied enum silently mismatches. `SourceEditorTokenType` is therefore declared with no cases
at all — values of it are only passed through, never matched on.
