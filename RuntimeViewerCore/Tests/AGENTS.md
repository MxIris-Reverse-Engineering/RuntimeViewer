# AGENTS.md — RuntimeViewerCore tests

How to build and run these suites: the root `AGENTS.md`, *Testing*.

- **Derived data stays in temporary directories.** A suite that reads or writes derived data works in a
  `DerivedDataTestDirectory` (`RuntimeViewerCoreTests/DerivedDataStorage/DerivedDataTestSupport.swift`), which
  makes a directory of its own under the temporary directory and removes it afterwards, and builds its
  stores with `DerivedDataTestIdentities.store(in:)`. Never let a test reach the real
  `~/Library/Caches/<bundle identifier>/DerivedData`: the app's services read whatever is there at their
  next launch, and the cleanup a store does at its first use deletes the directories it does not
  recognize as current.

Background: `Documentations/Evolutions/draft-derived-data.md`.
