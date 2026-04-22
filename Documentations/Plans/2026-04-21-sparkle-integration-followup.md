# Sparkle Integration — Outstanding Follow-up

The `feature/sparkle-integration` branch implements Tasks 2–14 of
`2026-04-21-sparkle-integration-plan.md`. Three items still require human
action and are listed here so they are not forgotten.

## 1. Task 1 — Generate the EdDSA key pair (local machine)

Requires your macOS login Keychain and password manager; cannot be
scripted from this repo.

Follow the plan's Task 1 steps:

```bash
cd /tmp
curl -L -o Sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.9.1.tar.xz"
mkdir -p Sparkle-unpacked && tar -xf Sparkle.tar.xz -C Sparkle-unpacked

/tmp/Sparkle-unpacked/bin/generate_keys             # Step 2: public key in stdout
/tmp/Sparkle-unpacked/bin/generate_keys -x sparkle_ed25519_priv.pem   # Step 3
base64 -i sparkle_ed25519_priv.pem | pbcopy         # Step 4: for CI secret
gpg --symmetric --cipher-algo AES256 sparkle_ed25519_priv.pem         # Step 5
shred -u sparkle_ed25519_priv.pem
```

Then:

- Replace `REPLACE_WITH_PUBLIC_ED_KEY_FROM_TASK_1` in
  `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Debug.xcconfig` and
  `Release.xcconfig` with the base64 public key printed by Step 2.
- Write the full runbook described in plan Task 1 Step 6 to
  `Documentations/SparkleRelease.md` and commit it.
- Keep the Step 4 base64 (private key PEM) in clipboard / password-manager
  secure notes; it is the value for Task 15 Step 1.

## 2. Task 15 — GitHub configuration (after PR merges to `main`)

Done entirely in the GitHub web UI; no commits.

- **Settings → Secrets and variables → Actions → New repository secret**
  - Name: `SPARKLE_EDDSA_PRIVATE_KEY`
  - Value: base64 PEM from Task 1 Step 4.
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

## 3. Tasks 11 & 16 — Validation (requires the EdDSA private key)

Task 11 (local dry-run against signed artifacts) and Task 16 (end-to-end
beta release after merge) both require `generate_appcast` to have access
to the private key — either via the login Keychain (default) or via the
`--ed-key-file` path.

- **Task 11 (local, pre-merge validation):**

  ```bash
  ./ReleaseScript.sh --version-tag v2.1.0-dryrun \
      --channel beta --update-appcast \
      --skip-notarization --skip-open-finder 2>&1 | xcsift
  ```

  Expected: new `<item>` in `docs/appcast.xml` with
  `<sparkle:channel>beta</sparkle:channel>` and matching EdDSA signature
  verifiable by `/tmp/Sparkle-unpacked/bin/sign_update RuntimeViewer-macOS.zip`.
  Then `git restore docs/appcast.xml && rm -f RuntimeViewer-macOS.zip &&
  rm -rf Products/Archives` to leave the tree clean.

- **Task 16 (post-merge RC):**

  ```bash
  git checkout main && git pull
  git tag -a v2.0.1-RC.1 -m "v2.0.1 Release Candidate 1: auto-update via Sparkle"
  git push origin v2.0.1-RC.1
  gh run watch
  ```

  Verify:
  - CI succeeds and uploads the GitHub Release (flagged pre-release).
  - `docs/appcast.xml` gains one beta `<item>`.
  - `curl` the Pages feed shows the new entry.
  - Install `v2.0.0`, opt into beta in Settings → Updates → Check Now,
    accept the offered upgrade, and confirm the new version launches.

Promote to stable by tagging `v2.0.1` only after the RC has run for
≥3 days with no regressions.

## Manual smoke test (anytime the feature branch builds)

Plan Task 6 Step 4 needs a manual eyeball:

1. Build and launch the Debug app.
2. Confirm the **RuntimeViewer-Debug** application menu has a new
   **Check for Updates…** item directly below **About**.
3. Click it. The Sparkle standard dialog should open. Feed fetch will
   fail until `docs/appcast.xml` is published (that is expected pre-merge).

No need to wait for the key before running this — the updater controller
initializes even with the placeholder `SPARKLE_PUBLIC_ED_KEY`; only actual
signature verification is blocked.
