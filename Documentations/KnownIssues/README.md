# Known Issues

Point-in-time records of issues discovered in code reviews that were not
blockers at the time of the review and therefore not fixed immediately. Each
dated file is a snapshot of a specific review pass; use them as a backlog
when picking up follow-up work.

## Conventions

- One file per review pass, named `YYYY-MM-DD-<context>-findings.md`.
- Each issue has a stable ID of the form `<slice>.<N>` so it can be referenced
  from commit messages and future reviews (`fix(M3.1): …`, `re: known-issue M6.2`).
- Severity is one of: **Blocker** (must fix before shipping), **Major** (real
  bug but ship-acceptable for now), **Minor** (polish), **False positive**
  (kept for bookkeeping so the same path isn't re-flagged next time).
- When an issue is fixed, update its row with the fix commit hash and leave
  the entry in place — don't delete — so the history is preserved.

## Files

- [2026-04-10-rc4-review-findings.md](2026-04-10-rc4-review-findings.md) —
  findings from the pre-v2.0.0-RC.4 parallel review of branch
  `feature/socket-injected-endpoint-reconnection` (9 slices, ~11.5k LOC).
  Three Blockers were fixed before this file was written; the rest of the
  Majors and Minors are tracked here.
- [2026-04-17-ultrareview-findings.md](2026-04-17-ultrareview-findings.md) —
  follow-up `/ultrareview` pass on the same branch @ `c88cb2b`. Six issues
  (3 Normal, 3 Nit); notably, UR.3 reactivates FP.4 because the new
  reconnection Task invalidates the original false-positive premise.
- [2026-04-30-engine-mirroring-routing-findings.md](2026-04-30-engine-mirroring-routing-findings.md) —
  field-report investigation against `chore/script-rename-and-engine-move`.
  Two Major issues in cross-host engine mirroring: EM.1 iOS/visionOS sidebar
  permanently loading because `requestEngineList` has no timeout and silently
  hangs on awdl0; EM.2 leaf-disconnect leaves stale device-name mirror in
  sidebar because Case-2 cleanup only matches by ownership, not by `engineID`
  prefix. Companion architecture walkthrough at
  [`Documentations/EngineMirroringWalkthrough.md`](../EngineMirroringWalkthrough.md).
- [2026-08-16-uifoundation-settings-adoption-review-findings.md](2026-08-16-uifoundation-settings-adoption-review-findings.md) —
  `/code-review` pass on `feature/uifoundation-settings-adoption` (PR #99).
  Fourteen findings, adjudicated one by one: eleven fixed in the same batch
  (two of them Blockers — the branch could not compile against its own
  declared dependency graph, and the settings window had stopped restoring its
  position — both requiring UIFoundation 0.17.0), US.6 ruled a **false
  positive** (non-macOS persistence: nothing off macOS writes a setting, so
  restoring it would be dead code), and US.11 / US.12 **deferred** to the
  `main` → `next` merge that already carries the `OutputTransformer`
  dependency fix.
- [2026-06-25-theme-settings-panel-review-findings.md](2026-06-25-theme-settings-panel-review-findings.md) —
  `/code-review` pass on `feature/theme-settings-panel` (PR #80). Four issues
  on the Theme settings UI: TS.1 ColorPicker / Name field write storm causing
  full re-render + autosave per frame; TS.2 editor's Light/Dark variant
  selector hardcoded to `.dark`; TS.3 duplicate-preset names not deduped;
  TS.4 toolbar font-size +/- read-modify-write not coalesced on auto-repeat.
- [2026-08-09-pr88-review-findings.md](2026-08-09-pr88-review-findings.md) —
  adjudications for the first (xhigh) review pass on PR #88
  (`perf/pipeline-optimizations`), IDs `PR88.<N>`: 7 fixed in-branch, 1 false
  positive (the RxAppKit `rx.state` no-initial-value premise, refuted at
  runtime), 7 backlogged (byte-budget-less interface cache, test
  infrastructure seams, docs placement).
- [2026-08-10-pr88-max-review-findings.md](2026-08-10-pr88-max-review-findings.md) —
  adjudications for the second (max) review pass on PR #88 after cross-session
  re-verification, IDs `PR88R2.<N>` mapping to findings F1–F15: 6 fixed
  in-branch (expansion-autosave wipe, root-filter stale overwrite, link-jump
  cache key mismatch, Open Quickly haystack discard / main-thread rebuild /
  unbounded materialization), 2 downgraded on re-verification (one-tick
  transformer skew, unreachable applyNodes guard), 1 claim refuted
  (specialization flushes the whole interface cache, so no dead entries),
  6 backlogged.
- [2026-08-13-pr88-max-review-findings.md](2026-08-13-pr88-max-review-findings.md) —
  adjudications for the third (max) review pass on PR #88, IDs `PR88R3.<N>`.
  No finding was a regression this round — every one is an optimization that
  covered only half its ground. 5 fixed in-branch (link-jump cache misses its
  own request key; fuzzy-mode title rebuild scanning the whole subtree
  haystack; Open Quickly haystack builds not deduplicated, per-keystroke sweep
  of the warm cell cache, and reload invalidation landing outside the turn
  that installs the nodes), 2 归并被推翻并独立登记 (root pipeline's
  cancellation check covers nothing — `PR88R2.15(d)`; object pipeline's
  snapshot descends into scope-pruned subtrees), 1 补注 on `PR88.9` (a second
  discard path introduced by the `PR88R2.1` fix), 5 false positive / no-fix —
  including the phantom-LRU-key claim **改判为可达但无害**, whose write-up
  records that fixing the cache-key finding makes it easier to reach.
- [2026-08-14-pr88-max-review-pass4-findings.md](2026-08-14-pr88-max-review-pass4-findings.md) —
  adjudications for the fourth (max) review pass on PR #88, IDs `PR88R4.<N>`.
  Every real finding this round sits inside the two commits written to fix the
  *third* pass (`37c7a47d`, `91e2169d`), which never got re-reviewed. 5 fixed
  in-branch (reload invalidation skipped on the `.notLoaded` / `.loadError`
  outcomes; a superseded Open Quickly pass rebuilding haystacks for a
  discarded object list; a stale redirect hiding a correct cache entry; the
  interface cache keyed by the whole recursive `RuntimeObject` instead of
  `RuntimeObjectKey`; dead haystack seeding), 1 test gap recorded honestly
  (`PR88R4.2`), 2 adjudicated away on adversarial re-review — the
  `ResolvedThemeStream` `.forever` claim **改判为既存问题且后果不成立**, and
  the Open Quickly 500-row cap **判为重报 `PR88R2.11`**. Also carries the
  AGENTS.md §9 and Evolution 0005 corrections this batch made.
  (`PR88R4.7` was later overturned — see the 2026-08-16 file.)
- [2026-08-16-pr100-review-findings.md](2026-08-16-pr100-review-findings.md) —
  adjudications for the fifth review pass on the same branch, now PR #100, IDs
  `PR100.<N>`. Only 8 of 15 findings were new; 4 were re-reports of already
  adjudicated entries. 4 fixed in-branch (Open Quickly's row cap truncating a
  tie of equally-scoring matches by name order; the root sidebar left wedged in
  filtering mode after a tree rebuild; the `.notLoaded` / `.loadError` outcomes
  re-seeding derived state from the previous load; the untested `.loadError`
  arm). Two adjudications changed direction: `PR88R4.7` is **overturned** —
  `fuzzyMatch` freezes its score once the pattern is consumed, so "sorted by
  weight" carries no discrimination — and this round's own proposal to narrow
  the `.specializationAdded` cache flush was **withdrawn** once
  `RuntimeSwiftSection.specialize` was read past its dispatch shell.
  3 recorded as latent/unreachable with the change that would activate each.
- [2026-08-22-simulator-injection-identity-findings.md](2026-08-22-simulator-injection-identity-findings.md) —
  self-audit of Evolution 0014's identity rework (`feature/inject-ios-simulator-process`),
  IDs `SIMID.<N>`. Not a review pass: it walks every consumer of
  `hostInfo.hostID` after that field moved from process-level (instanceID) to
  device-level (deviceID). 3 fixed in the same batch (mirrored engines landing
  in a section of their own because the mirror path derived `hostID` from
  `originChain.first`; `RuntimeSource.identifier` keying Bonjour clients by a
  display name two processes can share; teardown clearing the dedup tables by
  name after the key moved). `SIMID.4` records why the now-device-level prefix
  in `clearAllWithHostID` is left alone — its trigger set is empty while iOS
  payloads register no engine-list handler — together with the three changes
  that would reopen it. `SIMID.5` flags `SIMULATOR_UDID` as unverified until
  the end-to-end pass.
- [2026-08-27-pr106-cross-review-findings.md](2026-08-27-pr106-cross-review-findings.md) —
  second `/code-review xhigh` pass on PR #106, IDs `PR106X.<N>`, with every
  finding re-verified by *two* mutually unaware sessions before adjudication.
  5 fixed in-branch (the advertised Bonjour name regressing to a model name on
  iOS devices — a revert of `db8388dc`'s deliberate fix; a failed simulator
  payload build leaving the *previous* product for the embed phase to seal in
  while the log says it succeeded; a doc block that swallowed the function it
  documented; a stale DocC reference; the unregistered `TaskReports/`
  directory). `PR106X.4` (service name over the 63-byte DNS-SD limit) is a
  **false positive**: both sessions measured it, and mDNSResponder truncates on
  a UTF-8 boundary and registers anyway — `NWListener` still reaches `.ready`
  and the TXT record, which is what peer matching reads, is untouched.
  `PR106X.2` (a relaunched peer briefly showing a second, dead row) is
  **no-fix**: the obvious repair would kill the one legitimate case Evolution
  0014 exists for, several injected processes on one device. `PR106X.1` (the
  sidebar's autosave keys taking a peer's *process display name*) is deferred
  to the `RuntimeBookmarkScope` proposal together with `PR106.1` — and records
  why the obvious fix, switching those keys to `source.identifier`, is worse
  than the bug: that identifier carries the pid. `PR106X.6` (both payload
  bundles sharing one `CFBundleIdentifier`) keeps only its factual half; the
  "notarization rejects this" claim is marked unproven, and the real acceptance
  step is one full `ArchiveScript.sh` notarization run. `PR106X.10` is new this
  round and still unmeasured: `NWBrowser`'s `.changed` case is dropped
  entirely, which matters now that the service name survives a relaunch.

- [2026-08-24-pr106-review-findings.md](2026-08-24-pr106-review-findings.md) —
  `/code-review xhigh` pass on PR #106 (`feature/inject-ios-simulator-process`),
  IDs `PR106.<N>`, cross-reviewed by a second session before adjudication.
  14 findings: 11 fixed in-branch — among them the Bonjour service name
  carrying the pid (old hosts display a raw UUID *and* accumulate one
  `NSOutlineView` autosave key per peer launch), mirror cleanup missing the
  instance-level namespace after `hostID` went device-level, a trapping
  `Int(UInt64)` on a hostile fat-64 slice offset, injection confirmation
  matching on pid alone, and a duplicated `processName` fallback that names a
  target the empty string. `PR106.13` is a **false positive** — `return nil`
  versus `continue` on an unreadable fat entry is provably unobservable,
  because entries are contiguous and fixed-size, so once one is out of bounds
  every later one is too; both review passes had called it real. `PR106.14`
  (UDID in mDNS and in ~40 `.public` log sites) is deferred to its own
  proposal: it needs one privacy convention, not patches, and the salted-hash
  replacement must use a *fixed* salt or it re-splits one simulator into a
  section per injected process. `PR106.1` (Bonjour bookmarks keyed by a
  pid-bearing identifier, reversing `917002cc`'s deliberate stable identity) is
  deferred to its own PR, bundled with the pre-existing `@FileStorage` defect
  that lets a renamed peer silently overwrite another peer's bookmarks on
  decode. Also records 4 pre-existing `RuntimeViewerCore` test failures
  (reproduced on an untouched `69d8131b`) and a release path that can ship
  without the simulator payload behind a single `warning:` line.
- [2026-09-08-pr112-review-findings.md](2026-09-08-pr112-review-findings.md) —
  `/code-review xhigh` on `feature/command-line-interface` (PR #112, the
  `runtime-viewer-cli` foundation), re-verified adversarially by a second
  session that built the tool and ran the experiments. Fifteen findings plus
  one the review missed: fifteen fixed in the same batch, three registered as
  won't-fix. Two of the review's own claims were overturned on re-verification
  (the follow-up app-as-host cannot reach `PR112.11`; the handshake race is
  real but did not fire in 100 attempts), and `PR112.18` records why a
  settings schema drift cannot be reported from this layer at all —
  MetaCodable's `@Default` swallows it before the reader sees it.
- [2026-09-23-runtime-object-identity-review-findings.md](2026-09-23-runtime-object-identity-review-findings.md) —
  `/code-review xhigh` on Evolution 0021, which made `RuntimeObject`'s `==`
  mean identity (`dc0b739c`, `727720cc`, merged into `next` as `2f224d81`),
  IDs `OBJID.<N>`. Twelve findings: two regressions the change introduced —
  three guards it counted as identity questions actually depended on content
  (the Specialization pane stopped listing a newly generated specialization;
  the timeline and the active tab kept whichever form of a type arrived
  first) — and one older defect it froze in place (Swift conformers looked up
  by `displayName`, which a protocol nested in a type prints as its short
  name). Nine fixed or tidied in the same batch; `OBJID.8` is a **false
  positive** (Objective-C objects never have children to copy); `OBJID.4`
  stays as the user already decided (`ComparableBuildable` left alone);
  `OBJID.11` — `lhs` / `rhs` across every comparison operator and sort
  closure — was fixed repository-wide in a follow-up at the user's call.
- [2026-10-06-pr119-review-findings.md](2026-10-06-pr119-review-findings.md) —
  `/code-review max` on PR #119 (`feature/jailbroken-ios-injection`, five
  proposals, +12228/-630), IDs `PR119.<N>`, plus the four unaddressed Copilot
  comments as `PR119.C<N>` and one finding the review missed as `PR119.N1`.
  Twelve fixed in the same batch, among them a latent `SIGPIPE` that kills the
  app or the injected system daemon on any write to a reset peer (pre-existing
  on `main`, so it also got its own PR there), three defects in the device
  keep-awake assertion's lifetime that each contradicted the suspension design
  the same PR documents — released on a Wi-Fi blip, released at attach time
  when the payload advertises, and never released at all once the device
  reconnects — a new `RuntimeSource` case that made an older peer drop its
  whole mirror link, and a simulator misclassified as a remote device, which
  was a regression against `next`. `PR119.8` (optimistic `connected` window)
  and `PR119.12` (frozen glyph tint) are backlogged; `PR119.14` stays as
  written; `PR119.5` and `PR119.9` are **false positives** with their reopen
  conditions recorded, as is Copilot's claim-token comment. Copilot's
  no-authentication comment is **escalated to its own proposal** — the
  increment over the baseline is small, since an unauthenticated peer could
  already `dlopen` an arbitrary path, but the threat model deserves stating
  rather than patching. Also records four fixes that have no test seam, and
  why.
- [2026-10-07-pr121-review-findings.md](2026-10-07-pr121-review-findings.md) —
  `/code-review max` on `feature/find-navigator` (PR #121, the Find navigator
  and Report navigator proposals) @ `12e1227b`, IDs `PR121.<N>`. 54 defects
  plus performance and cleanup items, each re-verified against the code, and
  four findings the review missed (`PR121.70`–`73`, among them lock files
  pinned to a MachOSwiftSection revision orphaned by an upstream rebase).
  Written before any fix: every entry carries a draft diff against
  `12e1227b` (not compiled) and an example reproduction test, and the head of
  the file lists the decisions still open and the order to land the fixes in.
  As each entry is fixed, its diff is replaced by the fix commit.
- [2026-10-17-cross-references-review-findings.md](2026-10-17-cross-references-review-findings.md) —
  review of `feature/cross-references` (the cross references proposal, steps
  1–3) together with MachOSwiftSection's `feature/cross-reference-analysis`,
  IDs `XR.<finding>`. Fixed with a failing-first test each: type references
  carrying the queried object's whole subtree (`XR.C2`), an oversized scan
  pushing every other scan out of the session again on each query
  (`XR.C3`), and four tests that could not fail or could not tell what they
  claimed (`XR.D1`, `XR.D4`, `XR.C13`). Through the MachOSwiftSection pin:
  images outside the shared cache — an injected app's own executable,
  frameworks and plug-ins — answered `imageNotFound` (`XR.C1`), and C
  functions another library re-exports under a new name lost nearly all
  their cross-image callers. `XR.C4`, `C5`, `C7`, `C8`, `C11` are recorded as
  not fixed with their reopen conditions; `XR.C9` and `XR.B6` are **false
  positives**. The library's own findings live in its
  `Roadmaps/2026-10-17-cross-reference-analysis-review-findings.md`.
- [2026-10-21-pr125-review-findings.md](2026-10-21-pr125-review-findings.md) —
  `/code-review xhigh` on PR #125 (`chore/runtime-engine-session`, the
  RuntimeEngineSession proposal) @ `8cd5d2b5`, IDs `PR125.<N>`. Nine
  findings, none of them a serious correctness bug. Fixed with a failing-first
  test: the App Nap activity taken again by a report still on its way when the
  engine's work closed (`PR125.1`, there since the activity was introduced),
  and a test that slept 300 ms for the engine's first reload (`PR125.2`); two
  stale documentation passages fixed (`PR125.8`, `PR125.9`) and a misleading
  "immutable" reworded (`PR125.6`). `PR125.3`, `4`, `5`, `7` are recorded as
  not fixed with their reasons. Fixed in the same batch at the user's request:
  an engine coming back while a document had something open fired
  `.switchEngine` behind `MainCoordinator`'s back and failed its assertion, a
  crash in Debug builds (`PR125.10`, there since the local runtime moved into
  its XPC service).
- [2026-10-26-pr126-review-findings.md](2026-10-26-pr126-review-findings.md) —
  `/code-review xhigh` pass on PR #126 (`feature/derived-data`, the derived
  data proposal) @ `19fbf018`, IDs `PR126.<N>`: fifteen findings, plus one from
  Codex's automatic review (`PR126.16`) and one same-kind instance found while
  verifying (`PR126.17`). None is a crash. Fixed on the branch with a
  failing-first test: Find Type References and the Inspector's References tab
  missing an image that is searchable from derived data but not indexed yet
  (`PR126.1`, `PR126.17`), the content pane left blank when indexing finished
  between its two asks (`PR126.16`), images read back that a transformer change
  or the corpus switch going off and on dropped from search (`PR126.2`), images
  being read listed as queued in the Report (`PR126.4`), a decoded length of
  `Int.max` that trapped the reader (`PR126.6`), kind names that could be read
  as another kind's variants (`PR126.7`), and a test that relied on a 0.2 s
  sleep (`PR126.13`); plus a comment, abbreviations across the codebase and two
  access levels (`PR126.5`, `14`, `15`). `PR126.3`, `8`, `9`, `11`, `12` are
  recorded as not fixed and `PR126.10` as a false positive, with their reasons.
- [2026-10-27-pr127-review-findings.md](2026-10-27-pr127-review-findings.md) —
  `/code-review xhigh` on PR #127 (`feature/sidebar-filter-text-tokens`, the
  sidebar filter text tokens proposal) @ `744395d1`, IDs `PR127.<N>`. Fifteen
  findings, none blocking. Fixed with a failing-first test each: comparisons
  that followed the user's language, so a Mac in Turkish missed `UIView` for
  `uiview` (`PR127.5`, confirmed in a child process; the specialization type
  picker had the same flaw since May); the object list dropping its filter on
  every reload — after each batch of background indexing — while the field
  kept showing it (`PR127.9`, there since the first object list); a Filter
  Mode change that never filtered again (`PR127.2`, broken since February by
  an equality guard); typed token syntax fuzzy-matched under a Filter Mode
  (`PR127.3`); a Contains value starting with `!` inverting when edited
  (`PR127.4`); a lone `*` emptying the list mid-typing (`PR127.7`); and commas
  ending tokens in the Find results, which filter code (`PR127.8`). `PR127.1`
  — text being typed turned into a token by a menu action — is a **false
  positive**, shown by a test that now pins it. `PR127.6`, `10`, `12`, `14`,
  `15` are recorded as not fixed; `PR127.11`, an AppKitPlus API for recent
  filters, is deferred to a change of its own.
