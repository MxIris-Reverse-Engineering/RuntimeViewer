# 0001 - IDA Compatible ObjC Export Mode

- **Status**: Implemented
- **Date**: 2026-03-06
- **Last Updated**: 2026-03-06
- **Author**: JH

## Summary

Add an "IDA Compatible" export mode for Objective-C headers that maximizes information fidelity when importing into IDA Pro 9.3+. This mode generates three complementary outputs:

1. **Ivar layout structs** with IDA 9.3 `__fixed(size)` / `__at(offset)` annotations for precise memory layout reconstruction
2. **Clean ObjC headers** without custom comments, parseable by IDA's built-in Clang parser
3. **IMP mapping file** (`.ida_map`) that maps method implementation addresses to ObjC selectors

## Motivation

RuntimeViewer already exports high-quality ObjC header files, but IDA Pro cannot fully utilize them because:

- `// offset: N` and `// IMP: 0x...` comments are ignored by IDA's Clang parser
- The comments can sometimes cause parse errors depending on their content
- Ivar memory layout information (critical for reverse engineering) is lost during import
- Method implementation addresses require manual cross-referencing

IDA 9.3 introduced `__fixed(size)` and `__at(offset)` layout annotations that can express struct member offsets precisely. By generating ivar layouts in this format, we preserve the most valuable information RuntimeViewer provides — exact memory offsets — in a form IDA natively understands.

## Detailed Design

### 1. ObjCGenerationOptions Change

Add a single new option to `ObjCGenerationOptions` in `RuntimeObjCSection.swift`:

```swift
@Codable
@MemberInit
public struct ObjCGenerationOptions: Sendable, Equatable {
    // ... existing options ...

    @Default(false)
    public var idaCompatible: Bool
}
```

When `idaCompatible` is `true`, the following existing options are **force-overridden** during generation:

| Option | Forced Value | Reason |
|--------|-------------|--------|
| `addIvarOffsetComments` | `false` | Offsets expressed via `__at()` in ivar struct |
| `addMethodIMPAddressComments` | `false` | IMPs written to `.ida_map` file |
| `addPropertyAccessorAddressComments` | `false` | IMPs written to `.ida_map` file |
| `addPropertyAttributesComments` | `false` | `@synthesize`/`@dynamic` comments can confuse Clang |

This force-override happens in `ObjCDumpContext` initialization or at the call site in `RuntimeObjCSection.interface(for:using:transformer:)`, so the stored user preferences are not mutated.

### 2. Ivar Layout Struct Generation

For each `ObjCClassInfo` that has ivars, generate a companion struct **before** the `@interface` declaration:

```objc
struct __fixed(0x48) NSView_IVARS {
    __at(0x0008) CALayer *_layer;
    __at(0x0010) id _gestureRecognizers;
    __at(0x0018) NSRect _frame;
};

@interface NSView : NSResponder <NSAnimatablePropertyContainer> {
    CALayer *_layer;
    id _gestureRecognizers;
    NSRect _frame;
}
// properties and methods...
@end
```

Implementation in `ObjCDump+SemanticString.swift`:

- Add a new method `ObjCClassInfo.idaIvarLayoutStruct(using:)` that builds a `SemanticString` for the `__fixed`/`__at` struct
- Modify `ObjCClassInfo.semanticString(using:)` to prepend this struct when `context.options.idaCompatible && !ivars.isEmpty`
- The struct name follows the pattern `{ClassName}_IVARS`
- `__fixed` size comes from `ObjCClassInfo.instanceSize`
- `__at` offset comes from each `ObjCIvarInfo.offset`
- Ivar types use the same type rendering as existing ivar generation

### 3. IMP Address Collection

Add a new data structure to collect IMP addresses during export:

```swift
public struct RuntimeIMPMapping: Sendable {
    public let address: String    // "0x00001234"
    public let selector: String   // "-[NSView setFrame:]"
}
```

Collection happens in `RuntimeObjCSection.interface(for:using:transformer:)` — the method already iterates methods and has access to `ObjCMethodInfo.imp`. When `idaCompatible` is true, collect mappings into a list stored on a new property of `ObjCDumpContext` or returned alongside the `RuntimeObjectInterface`.

The approach: extend `RuntimeObjectInterface` to optionally carry IMP mappings:

```swift
public struct RuntimeObjectInterface: Sendable {
    public let object: RuntimeObject
    public let interfaceString: SemanticString
    public let impMappings: [RuntimeIMPMapping]  // empty when not IDA mode
}
```

### 4. Export Writer Changes

In `RuntimeInterfaceExportWriter`, after writing all ObjC headers, if IDA compatible mode is active:

- Collect all `RuntimeIMPMapping` from all exported items
- Sort by address
- Write to `<imageName>.ida_map` in the export directory

Format:
```
# RuntimeViewer IDA IMP Mapping
# Image: UIKitCore
0x00001234 -[NSView frame]
0x00001240 -[NSView setFrame:]
0x00001280 +[NSView layerClass]
```

### 5. Export Configuration

Add `idaCompatible` to `RuntimeInterfaceExportConfiguration`:

```swift
public struct RuntimeInterfaceExportConfiguration: Sendable {
    // ... existing fields ...
    public let idaCompatible: Bool
}
```

### 6. ExportingState & UI

Add to `ExportingState`:

```swift
@Observed
var idaCompatible: Bool = false
```

In `ExportingConfigurationViewController`, add a checkbox below the ObjC format radio buttons:

```
[x] IDA Compatible
    Generate ivar layout structs and IMP mapping file for IDA Pro 9.3+
```

The checkbox is only visible when ObjC content is present (follows the same `hasObjC` visibility logic).

In `ExportingConfigurationViewModel`, add the checkbox signal to `Input` and bind it to `exportingState.idaCompatible`.

### 7. GenerationOptions Preset

Add a static preset for IDA-compatible generation:

```swift
extension RuntimeObjectInterface.GenerationOptions {
    public static let ida = GenerationOptions(
        objcHeaderOptions: ObjCGenerationOptions(
            stripProtocolConformance: false,
            stripOverrides: false,
            stripSynthesizedIvars: false,
            stripSynthesizedMethods: false,
            stripCtorMethod: true,
            stripDtorMethod: true,
            addIvarOffsetComments: false,
            addPropertyAttributesComments: false,
            addMethodIMPAddressComments: false,
            addPropertyAccessorAddressComments: false,
            idaCompatible: true
        )
    )
}
```

Note: `.cxx_construct` and `.cxx_destruct` are stripped by default in IDA mode as they are compiler-generated and not useful for type reconstruction.

## Impact on Existing Functionality

- **No breaking changes**: `idaCompatible` defaults to `false`, preserving all existing behavior
- **SemanticString rendering**: The ivar layout struct is prepended only when `idaCompatible` is true
- **Export flow**: The `.ida_map` file is an additional output, existing files are unchanged
- **Settings persistence**: The new option is `@Codable` and persisted via `MetaCodable` like existing options

## File Changes

| File | Change |
|------|--------|
| `RuntimeObjCSection.swift` | Add `idaCompatible` to `ObjCGenerationOptions` |
| `ObjCDump+SemanticString.swift` | Add `idaIvarLayoutStruct()`, modify `ObjCClassInfo.semanticString()` |
| `RuntimeObjectInterface+GenerationOptions.swift` | Add `.ida` preset |
| `RuntimeInterfaceExportConfiguration.swift` | Add `idaCompatible` field |
| `RuntimeInterfaceExportWriter.swift` | Add `.ida_map` file generation |
| `RuntimeInterfaceExportEvent.swift` | Add `RuntimeIMPMapping` type |
| `ExportingState.swift` | Add `idaCompatible` property |
| `ExportingConfigurationViewModel.swift` | Add checkbox input/output binding |
| `ExportingConfigurationViewController.swift` | Add IDA Compatible checkbox |
| `ExportingProgressViewModel.swift` | Pass `idaCompatible` to configuration |

## Alternatives Considered

### A. Comments-only cleanup (no `__fixed`/`__at`)
Simply strip all `// offset:` and `// IMP:` comments. Easy to implement but loses the most valuable information — ivar offsets.

### B. Inline `__at()` in @interface ivar block
IDA's Clang parser does not support `__at()` inside `@interface { }` blocks — it only works on struct members. Would cause parse errors.

### C. IDAPython post-processing script
Ship a Python script that parses RuntimeViewer's comment format and applies types via IDA API. More flexible but requires users to manage a separate script and has a more fragile parsing pipeline.

## Decision Log

| Date | Decision | Details |
|------|----------|---------|
| 2026-03-06 | Created as Draft | Add IDA Compatible export mode with ivar layout structs, clean headers, and IMP mapping file |
| 2026-03-06 | Changed to In Progress | Implementation started |
| 2026-03-06 | Changed to Implemented | All changes implemented and build verified |
