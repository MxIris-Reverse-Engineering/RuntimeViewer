# Sparkle Release Runbook

This file documents the release process, EdDSA key management, and emergency
recovery for RuntimeViewer's Sparkle-based auto-updates. For the high-level
architecture and design rationale, see
`Documentations/Plans/2026-04-21-sparkle-integration-design.md`.

## Release cadence

A public release is cut by pushing an annotated git tag matching:

- `v<MAJOR>.<MINOR>.<PATCH>` — stable release.
- `v<MAJOR>.<MINOR>.<PATCH>-RC.<N>` / `-beta.<N>` / `-alpha.<N>` — pre-release.

`ReleaseScript.sh` (and the `release.yml` workflow) infer the Sparkle channel
from the tag: anything matching `*-RC*|*-beta*|*-alpha*` goes into the `beta`
channel, everything else goes into `stable`. Pass `--channel` explicitly to
override. Pre-releases are only offered to clients that opt in via
**Settings → Updates → Include pre-release versions**; stable releases go to
all users.

Release notes live at `Changelogs/<tag>.md` and are picked up automatically by
`release.yml` when that file exists.

## Local release (manual)

Substitute the version tag in the example below for whichever release you are
cutting (e.g. `v2.0.0-RC.4`, `v2.0.0`, `v2.1.0`).

```bash
./ReleaseScript.sh --version-tag v2.0.0 \
                   --release-notes Changelogs/v2.0.0.md \
                   --update-appcast --upload-to-github --commit-push
```

Drop `--upload-to-github` and `--commit-push` (and optionally `--update-appcast`)
for a local dry-run that only produces the signed, notarized zip under
`Products/Archives/`. Useful flags for iteration:

- `--channel beta` — force a pre-release channel (otherwise inferred).
- `--skip-notarization` — skip the Apple notarization round-trip (dry-run only;
  must NOT be used for the actual release).
- `--skip-open-finder` — don't open Finder to the output on success.
- `--ed-key-file <path>` — sign with an explicit PEM instead of the login
  Keychain; used by CI.

Run `./ReleaseScript.sh --help` for the full list.

## CI release (automatic)

Push an annotated `v*` tag, or dispatch the workflow manually:

```bash
gh workflow run release.yml -f tag=v2.0.0                           # stable, channel inferred
gh workflow run release.yml -f tag=v2.0.0-RC.4 -f channel=beta
gh workflow run release.yml -f tag=v2.0.0 -f create_release=false   # build only
```

CI watches `.github/workflows/release.yml`; it decodes the
`SPARKLE_EDDSA_PRIVATE_KEY` secret to a tempfile and passes
`--ed-key-file` to `ReleaseScript.sh`. Tag pushes always create/upload the
GitHub Release and commit the updated `docs/appcast.xml` back to `main`.

## EdDSA key management

**Identity scope:** this key is shared across other Sparkle-signed apps
published under the same developer identity. Rotating it (Key-loss recovery
below) affects every app that uses it — coordinate before regenerating.

**Daily use:** the private key lives in the macOS login Keychain as item
`"Private key for signing Sparkle updates"` (account `ed25519`, service
`https://sparkle-project.org`). `generate_appcast` reads it automatically
when invoked without `--ed-key-file`, which is what local runs of
`ReleaseScript.sh` rely on.

**CI use:** the same private key is stored as GitHub repo secret
`SPARKLE_EDDSA_PRIVATE_KEY` in base64-encoded PEM form. The workflow decodes
it into `$RUNNER_TEMP/sparkle_ed25519_priv.pem` and passes `--ed-key-file`
explicitly.

**Cold backup:** kept as a GPG-symmetric-encrypted PEM
(`sparkle_ed25519_priv.pem.gpg`, AES256) in at least two offline locations
(encrypted external drive + password-manager secure attachment). The GPG
passphrase is stored in the password manager only — never in plaintext, never
in git.

**Public key:** `SPARKLE_PUBLIC_ED_KEY` in
`RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/{Debug,Release}.xcconfig`.
Gets baked into `Info.plist`'s `SUPublicEDKey` at build time. Sparkle uses it
client-side to verify every downloaded archive.

## Key-loss recovery

**If the login Keychain is wiped but offline backups are intact:**

```bash
gpg --decrypt sparkle_ed25519_priv.pem.gpg > sparkle_ed25519_priv.pem
/path/to/Sparkle-<version>/bin/generate_keys -f sparkle_ed25519_priv.pem
gshred -u sparkle_ed25519_priv.pem      # or: rm -P sparkle_ed25519_priv.pem
```

`-f` re-imports the key into the Keychain under the original item name. After
that, local `ReleaseScript.sh` runs work again without `--ed-key-file`.

**If both the Keychain copy and every offline backup are lost:**

1. Generate a new EdDSA key pair with `generate_keys` and re-export a PEM.
2. Replace `SPARKLE_PUBLIC_ED_KEY` in `Debug.xcconfig` and `Release.xcconfig`
   with the new public key; rotate the `SPARKLE_EDDSA_PRIVATE_KEY` repo
   secret with the new base64 PEM.
3. Ship the next release with the new public key.
4. Publish a notice in the README and in the next GitHub Release explaining
   that **already-installed clients cannot auto-update to this release** and
   must manually download it once. Subsequent updates resume normally.

Because this key is shared, a full rotation must be coordinated with every
other app that trusts the current public key.

## Rolling back a bad release

Sparkle never downgrades, so:

- **Preferred:** ship a higher-versioned hotfix ASAP. Users auto-upgrade away
  from the broken build.
- **Fallback:** hide the bad release from the default channel — mark its
  GitHub Release as pre-release (`gh release edit <tag> --prerelease`), then
  delete its `<item>` from `docs/appcast.xml`, commit, and push. Users still
  on the good version stop seeing the broken update offer; already-upgraded
  users need the hotfix.

## Verifying a signed archive locally

```bash
/path/to/Sparkle-<version>/bin/sign_update RuntimeViewer-macOS.zip
```

Prints the EdDSA signature. Use this if you ever need to hand-edit an
`<item>`'s `sparkle:edSignature` (e.g., after recovering the key from
backup).

## Where things live

- Feed URL: `https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml`
- Feed source: `docs/appcast.xml` on the `main` branch; served by GitHub Pages
  (source = `main` / `/docs`).
- Public key: `SPARKLE_PUBLIC_ED_KEY` in
  `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/{Debug,Release}.xcconfig`
  → baked into `Info.plist`'s `SUPublicEDKey`.
- Feed URL declaration: `Info.plist` key `SUFeedURL` (hardcoded because
  xcconfig's `//` comment rule mangles URLs).
- Release notes: `Changelogs/<tag>.md`.
- CI workflow: `.github/workflows/release.yml`.
- Release driver: `ReleaseScript.sh`.
- Outstanding integration follow-ups:
  `Documentations/Plans/2026-04-21-sparkle-integration-followup.md`.
