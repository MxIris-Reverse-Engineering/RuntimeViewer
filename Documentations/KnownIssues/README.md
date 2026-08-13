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
- [2026-06-25-theme-settings-panel-review-findings.md](2026-06-25-theme-settings-panel-review-findings.md) —
  `/code-review` pass on `feature/theme-settings-panel` (PR #80). Four issues
  on the Theme settings UI: TS.1 ColorPicker / Name field write storm causing
  full re-render + autosave per frame; TS.2 editor's Light/Dark variant
  selector hardcoded to `.dark`; TS.3 duplicate-preset names not deduped;
  TS.4 toolbar font-size +/- read-modify-write not coalesced on auto-repeat.
- [2026-08-09-pr88-review-findings.md](2026-08-09-pr88-review-findings.md) —
  cross-session adjudication of the PR #88 (`perf/pipeline-optimizations`)
  review: 7 findings fixed in the same batch (commits recorded per row),
  PR88.1 retracted as a false positive with the runtime evidence — the
  RxCocoa-vs-RxAppKit control-property priming boundary (`rx.state` has an
  initial value, `rx.isCheck` does not) is the part worth remembering — and
  7 backlog items with pickup conditions.
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
