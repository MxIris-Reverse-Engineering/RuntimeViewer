# AGENTS.md — RuntimeViewerCore tests

How to build and run these suites: the root `AGENTS.md`, *Testing*.

- **Derived data stays in temporary directories.** A suite that reads or writes derived data works in a
  `DerivedDataTestDirectory` (`RuntimeViewerCoreTests/DerivedDataStorage/DerivedDataTestSupport.swift`), which
  makes a directory of its own under the temporary directory and removes it afterwards, and builds its
  stores with `DerivedDataTestIdentities.store(in:)`. Never let a test reach the real
  `~/Library/Caches/<bundle identifier>/DerivedData`: the app's services read whatever is there at their
  next launch, and the cleanup a store does at its first use deletes the directories it does not
  recognize as current.
- **Never call `RuntimeDerivedData.enableInThisProcess()` in a test.** The switch is for the two service
  entry points; once on, it stays on for the whole test process, and every engine made afterwards would
  read and write the real location. An engine under test gets a store of its own through
  `RuntimeEngine.useDerivedDataStore(_:)`, a corpus store through its `derivedData:` parameter.
- **Never call `RuntimeTypeNames.enableInThisProcess()` in a test either.** It turns on the SDK type index,
  which would read the installed SDK, run sourcekitd for minutes and write the application's
  `~/Library/Caches/<bundle identifier>/TypeIndex` (or the command-line tool's). A test process prints
  `__C.` names; what the index resolves is tested in swift-type-indexing and MachOSwiftSection.

Background: `Documentations/Evolutions/0061-derived-data.md`; for the type index, MachOSwiftSection's proposal
`swift-type-indexing-package`.
