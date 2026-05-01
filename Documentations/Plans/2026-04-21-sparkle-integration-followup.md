# Sparkle Integration — Outstanding Follow-up

The `feature/sparkle-integration` branch implements Tasks 1–14 of
`2026-04-21-sparkle-integration-plan.md`, including the EdDSA key pair and
the release runbook (`Documentations/SparkleRelease.md`). The items below
still require human action and are listed here so they are not forgotten.

## 1. Task 15 — GitHub configuration (after PR merges to `main`)

Done entirely in the GitHub web UI; no commits.

- **Settings → Secrets and variables → Actions → New repository secret**
  - Name: `SPARKLE_EDDSA_PRIVATE_KEY`
  - Value: the base64-encoded private-key PEM stored during key generation
    (see `Documentations/SparkleRelease.md` → EdDSA key management).
- **Settings → Pages**
  - Source: **Deploy from a branch**
  - Branch: `main`, folder `/docs`
  - Save.
- **Settings → Actions → General → Workflow permissions**
  - Read and write permissions.
  - Save.

Pages propagation usually takes under 10 minutes after first merge. Verify
the feed URL:

```bash
curl -sI https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml
```

## 2. Tasks 11 & 16 — Validation (requires the EdDSA private key)

Task 11 (local dry-run against signed artifacts) and Task 16 (end-to-end
beta release after merge) both require `generate_appcast` to have access
to the private key — either via the login Keychain (default) or via the
`--ed-key-file` path.

- **Task 11 (local, pre-merge validation):**

  ```bash
  ./ArchiveScript.sh --version-tag v2.1.0-dryrun \
      --channel beta --update-appcast \
      --skip-notarization --skip-open-finder 2>&1 | xcsift
  ```

  Expected: new `<item>` in `docs/appcast.xml` with
  `<sparkle:channel>beta</sparkle:channel>` and matching EdDSA signature.
  Verify the signature with `sign_update RuntimeViewer-macOS.zip` from a
  locally unpacked Sparkle tarball (see `Documentations/SparkleRelease.md`
  for how the tools are obtained).
  Then `git restore docs/appcast.xml && rm -f RuntimeViewer-macOS.zip &&
  rm -rf Products/Archives` to leave the tree clean.

- **Task 16 (post-merge RC for v2.0.0):**

  The next RC after merge is `v2.0.0-RC.4` — the first build to include
  Sparkle. Users on `v2.0.0-RC.3` or earlier **cannot auto-update** to it
  (those builds ship without Sparkle) and must install it manually once;
  every subsequent release then flows through Sparkle.

  ```bash
  git checkout main && git pull
  git tag -a v2.0.0-RC.4 -m "v2.0.0 Release Candidate 4: auto-update via Sparkle"
  git push origin v2.0.0-RC.4
  gh run watch
  ```

  Verify:
  - CI succeeds and uploads the GitHub Release (flagged pre-release).
  - `docs/appcast.xml` gains one beta `<item>` with the new signature.
  - `curl` the Pages feed shows the new entry.
  - Install `v2.0.0-RC.4` manually on a clean machine; confirm Sparkle
    initializes and **Check for Updates…** works.
  - After cutting the next tag (`v2.0.0` stable, or another RC), the
    installed RC.4 should offer the upgrade via Settings → Updates →
    Check Now and install it cleanly end-to-end.

Promote to stable by tagging `v2.0.0` only after RC.4 has run for ≥3 days
with no regressions.

## Manual smoke test (anytime the feature branch builds)

Plan Task 6 Step 4 needs a manual eyeball:

1. Build and launch the Debug app.
2. Confirm the **RuntimeViewer-Debug** application menu has a new
   **Check for Updates…** item directly below **About**.
3. Click it. The Sparkle standard dialog should open. Feed fetch will
   404 until GitHub Pages starts serving `docs/appcast.xml` after merge
   (expected pre-merge).
