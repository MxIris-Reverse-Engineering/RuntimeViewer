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
