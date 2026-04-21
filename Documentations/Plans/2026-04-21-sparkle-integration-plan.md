# Sparkle Auto-Update Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Sparkle 2 auto-update into RuntimeViewer (macOS) with single-feed EdDSA channels, and replace `ArchiveScript.sh` + the bloated CI workflow with a shared `ReleaseScript.sh` that both local dev and CI invoke.

**Architecture:** A dedicated `UpdaterService` singleton owns `SPUStandardUpdaterController`, installs the menu item programmatically, implements `SPUUpdaterDelegate`, and binds bidirectionally to a new `Settings.Update` model. `AppDelegate` gains only `UpdaterService.shared.start()` / `.stop()`. Publishing flows through `ReleaseScript.sh` which archives, notarizes, runs `generate_appcast` against a preserved `docs/appcast.xml`, and optionally uploads to GitHub Releases plus commits+pushes the appcast. CI decodes its secrets and calls the same script with CI flags.

**Tech Stack:** Sparkle 2 (SPM), SwiftUI (Settings page), swift-dependencies (`@Dependency(\.settings)`), MetaCodable (Settings model macros), xcodebuild + xcsift (builds), `notarytool`, `generate_appcast`, `gh` CLI, GitHub Actions, GitHub Pages.

**Design spec:** `Documentations/Plans/2026-04-21-sparkle-integration-design.md` is the authoritative design reference. This plan executes that spec.

**Branch:** All work happens on `feature/sparkle-integration` (already created and contains the design doc).

---

## Prerequisites (one-time, before Task 1)

Confirm the following before starting:

- Working directory: `/Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer`
- Branch: `feature/sparkle-integration` — run `git branch --show-current` to verify.
- Tools available: `gh` CLI authenticated, `xcsift` installed, `xcodebuild` ≥ Xcode 15, network access to download Sparkle release tarball.
- MCP: `xcodeproj` MCP server available (for pbxproj mutations). Otherwise fall back to Xcode-GUI equivalents noted in each task.

---

## Task 1: Generate EdDSA key pair and write the release runbook

**Files:**
- Create: `Documentations/SparkleRelease.md`

- [ ] **Step 1: Download the Sparkle release tarball**

```bash
cd /tmp
curl -L -o Sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.6.0.tar.xz"
# Check Sparkle's releases page first; update version to the latest 2.x stable.
mkdir -p Sparkle-unpacked && tar -xf Sparkle.tar.xz -C Sparkle-unpacked
ls Sparkle-unpacked/bin/generate_keys
```

Expected: the `generate_keys` executable exists at `Sparkle-unpacked/bin/generate_keys`.

- [ ] **Step 2: Generate EdDSA key pair**

```bash
/tmp/Sparkle-unpacked/bin/generate_keys
```

Expected output includes a base64 public key like:

```
A key has been generated and saved in your keychain. Public key (SUPublicEDKey value):
SgsP+Cb1Kl...AbCd==
```

Copy the public-key string. The private key is now stored in the login Keychain as item `"Private key for signing Sparkle updates"` (account `ed25519`).

- [ ] **Step 3: Export a cold backup of the private key**

```bash
cd /tmp
/tmp/Sparkle-unpacked/bin/generate_keys -x sparkle_ed25519_priv.pem
ls -la sparkle_ed25519_priv.pem
```

Expected: the PEM file exists and is several hundred bytes.

- [ ] **Step 4: Base64-encode for the CI secret and copy to clipboard**

```bash
base64 -i sparkle_ed25519_priv.pem | pbcopy
```

Paste this into a secure notes file for the Task 15 step that sets the GitHub repo secret. Do not commit it.

- [ ] **Step 5: Encrypt + store the cold backup, then shred the plaintext**

```bash
gpg --symmetric --cipher-algo AES256 sparkle_ed25519_priv.pem
# Enter a strong passphrase when prompted. Store the passphrase in your
# password manager.
ls sparkle_ed25519_priv.pem.gpg
shred -u sparkle_ed25519_priv.pem
```

Expected: `sparkle_ed25519_priv.pem.gpg` exists; the unencrypted file is gone. Copy the encrypted file to at least two locations (offline encrypted drive + password-manager secure attachment) before proceeding.

- [ ] **Step 6: Write `Documentations/SparkleRelease.md`**

Create the runbook with these sections:

```markdown
# Sparkle Release Runbook

This file documents the release process, key management, and emergency
recovery for RuntimeViewer's Sparkle-based auto-updates.

## Release cadence

A new public release is cut by pushing an annotated git tag that matches
`v<MAJOR>.<MINOR>.<PATCH>` (stable) or `v<MAJOR>.<MINOR>.<PATCH>-RC.<N>` /
`-beta.<N>` / `-alpha.<N>` (prerelease). CI infers the Sparkle channel from
the tag; prereleases land in the `beta` channel and are only offered to
clients that opt in via Settings → Updates → "Include pre-release versions".

## Local release (manual)

```bash
./ReleaseScript.sh --version-tag v2.1.0 \
                   --release-notes Changelogs/v2.1.0.md \
                   --update-appcast --upload-to-github --commit-push
```

Omit `--upload-to-github` and `--commit-push` for a dry-run that only
produces the zip locally.

## CI release (automatic)

Push an annotated tag matching `v*`, or run the `release.yml` workflow
manually via `gh workflow run release.yml -f tag=v2.1.0 -f channel=stable`.

## EdDSA key management

**Daily use:** the private key lives in the macOS login Keychain as
`"Private key for signing Sparkle updates"` (account `ed25519`).
`generate_appcast` reads this automatically when invoked without
`--ed-key-file`.

**CI use:** the private key is duplicated into the GitHub repo secret
`SPARKLE_EDDSA_PRIVATE_KEY` as base64-encoded PEM. CI decodes it into a
temporary file and passes `--ed-key-file` to `ReleaseScript.sh`.

**Cold backup:** the key is also kept as a GPG-encrypted PEM
(`sparkle_ed25519_priv.pem.gpg`) in two offline locations (encrypted
external drive + password-manager secure attachment). The GPG passphrase
lives in the password manager only.

## Key-loss recovery

If the login Keychain is wiped but backups are intact:

```bash
gpg --decrypt sparkle_ed25519_priv.pem.gpg > sparkle_ed25519_priv.pem
/path/to/Sparkle/bin/generate_keys -f sparkle_ed25519_priv.pem
shred -u sparkle_ed25519_priv.pem
```

If both the Keychain copy and all offline backups are lost:

1. Generate a new EdDSA key pair (`generate_keys`) and re-export.
2. Update `SPARKLE_PUBLIC_ED_KEY` in `Debug.xcconfig` and
   `Release.xcconfig`, and rotate the `SPARKLE_EDDSA_PRIVATE_KEY` secret.
3. Ship the next release with the new public key.
4. Publish a notice in the README and the next GitHub Release explaining
   that already-installed clients cannot auto-update to this release and
   must manually download it once. Subsequent updates resume as normal.

## Rolling back a bad release

Sparkle never downgrades, so:

- Ship a higher-versioned hotfix ASAP.
- If a hotfix is not ready, hide the bad release from the default channel:
  `gh release edit <tag> --prerelease` and delete its `<item>` from
  `docs/appcast.xml` manually (commit + push). Already-upgraded users are
  unaffected; new clients stop seeing the update.

## Verifying a signed archive locally

```bash
/path/to/Sparkle/bin/sign_update RuntimeViewer-macOS.zip
# Prints the EdDSA signature for manual insertion if needed.
```

## Where things live

- Feed URL: `https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml`
- Feed source: `docs/appcast.xml` on the `main` branch; served by GitHub Pages (source = `main` / `/docs`).
- Public key in `Debug.xcconfig` and `Release.xcconfig`: `SPARKLE_PUBLIC_ED_KEY`.
- Release notes source: `Changelogs/<tag>.md`.
```

- [ ] **Step 7: Commit the runbook and checkpoint the key value**

```bash
git add Documentations/SparkleRelease.md
git commit -m "docs: add Sparkle release runbook and key-management procedures"
```

Keep the clipboard copy of the base64 private key for Task 15. Keep the public key string for Task 3.

---

## Task 2: Add Sparkle SPM dependency to the Xcode project

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj`

- [ ] **Step 1: Confirm current package dependencies**

```bash
grep -A1 'XCRemoteSwiftPackageReference' \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj \
  | head -30
```

Expected: a list of existing remote packages (CocoaCoordinator, RxAppKit, etc.). Sparkle should not appear yet.

- [ ] **Step 2: Add Sparkle via xcodeproj MCP (preferred) or Xcode GUI (fallback)**

**Via xcodeproj MCP:** invoke the MCP tool to add a package dependency and a product link in one operation. The package URL is `https://github.com/sparkle-project/Sparkle`, version rule `upToNextMajor(from: "2.6.0")` (replace with the latest 2.x stable at execution time), product `Sparkle`, target `RuntimeViewerUsingAppKit`.

**Fallback (GUI):** open `RuntimeViewer.xcworkspace` in Xcode → select project → Package Dependencies → `+` → URL `https://github.com/sparkle-project/Sparkle` → Dependency Rule "Up to Next Major Version" from `2.6.0` → Add → in the next sheet pick "Add to Target: RuntimeViewerUsingAppKit" and select product `Sparkle` only. Close Xcode, then move on to Step 3.

- [ ] **Step 3: Verify the dependency is registered in pbxproj**

```bash
grep -E 'sparkle-project|Sparkle\.framework|XCRemoteSwiftPackageReference.*Sparkle' \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj \
  | head -20
```

Expected: at least one line mentioning `github.com/sparkle-project/Sparkle` and one line linking `Sparkle` as a product to the main target. Do NOT link Sparkle to `RuntimeViewerCatalystHelper`.

- [ ] **Step 4: Verify the workspace resolves and builds**

```bash
xcodebuild -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' -resolvePackageDependencies 2>&1 | xcsift
```

Expected: `Sparkle` appears in the resolved package list, no errors.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj
git commit -m "chore: add Sparkle 2 SPM dependency to RuntimeViewerUsingAppKit target"
```

---

## Task 3: Add Sparkle keys to xcconfig and Info.plist

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Debug.xcconfig`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Release.xcconfig`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Info.plist`

- [ ] **Step 1: Append to `Debug.xcconfig`**

Append (keep the existing `SMPrivilegedExecutable` line untouched):

```
SPARKLE_FEED_URL = https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml
SPARKLE_PUBLIC_ED_KEY = <paste the base64 public key from Task 1 step 2>
```

Replace the placeholder with the actual key value.

- [ ] **Step 2: Append to `Release.xcconfig`**

Append the same two lines (identical values):

```
SPARKLE_FEED_URL = https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml
SPARKLE_PUBLIC_ED_KEY = <paste the base64 public key from Task 1 step 2>
```

- [ ] **Step 3: Extend `Info.plist` with Sparkle keys**

Edit `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Info.plist`. Inside the outer `<dict>` (before the closing `</dict>`), add four keys, preserving existing entries:

```xml
<key>SUFeedURL</key>
<string>$(SPARKLE_FEED_URL)</string>
<key>SUPublicEDKey</key>
<string>$(SPARKLE_PUBLIC_ED_KEY)</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUAllowsAutomaticUpdates</key>
<true/>
```

- [ ] **Step 4: Build to confirm variable expansion**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: build succeeds; if it fails because `SPARKLE_PUBLIC_ED_KEY` is empty or malformed, the error will be about Info.plist variable expansion. Confirm the xcconfig value matches the output of `generate_keys` step exactly.

After a successful build, spot-check the produced `RuntimeViewer-Debug.app/Contents/Info.plist`:

```bash
APP_PATH=$(xcodebuild -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)
plutil -extract SUFeedURL raw "$APP_PATH/RuntimeViewer-Debug.app/Contents/Info.plist"
plutil -extract SUPublicEDKey raw "$APP_PATH/RuntimeViewer-Debug.app/Contents/Info.plist"
```

Expected: prints the feed URL and the public key as plain values (not `$(SPARKLE_*)` literals).

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Debug.xcconfig \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Release.xcconfig \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Info.plist
git commit -m "feat: wire Sparkle feed URL, public key, and default behavior flags"
```

---

## Task 4: Add `Settings.Update` model and integrate into `Settings`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Update.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift`

- [ ] **Step 1: Create `Settings+Update.swift`**

```swift
import Foundation
import MetaCodable

extension Settings {
    @Codable
    @MemberInit
    public struct Update {
        @Default(true)
        public var automaticallyChecks: Bool

        @Default(false)
        public var automaticallyDownloads: Bool

        @Default(CheckInterval.daily)
        public var checkInterval: CheckInterval

        @Default(false)
        public var includePrereleases: Bool

        public static let `default` = Self()

        /// Maps to `SPUUpdater.setAllowedChannels(_:)` and
        /// `SPUUpdaterDelegate.allowedChannels(for:)`.
        ///
        /// Sparkle semantics: entries without a `<sparkle:channel>` tag are
        /// the "default channel" and are always visible. An empty set means
        /// "default channel only"; `["beta"]` means "default + beta".
        public var allowedChannels: Set<String> {
            includePrereleases ? ["beta"] : []
        }
    }

    public enum CheckInterval: String, Codable, CaseIterable {
        case hourly
        case daily
        case weekly

        public var timeInterval: TimeInterval {
            switch self {
            case .hourly: 3_600
            case .daily: 86_400
            case .weekly: 604_800
            }
        }

        public var displayName: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
    }
}
```

- [ ] **Step 2: Add `update` field to `Settings` and extend `load()`**

Edit `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift`. Find the block with the four existing `@Default(...) public var ...` declarations. After `mcp`, insert:

```swift
    @Default(Update.default)
    public var update: Update = .init() {
        didSet { scheduleAutoSave() }
    }
```

Then find the `load()` method. After the line `mcp = decoded.mcp`, insert:

```swift
            update = decoded.update
```

- [ ] **Step 3: Build the package to confirm it compiles**

```bash
cd RuntimeViewerPackages
swift package update
swift build --target RuntimeViewerSettings 2>&1 | xcsift
cd ..
```

Expected: build succeeds with zero warnings.

- [ ] **Step 4: Smoke-test `allowedChannels` logic with an ad-hoc snippet**

Use `xed` / Xcode Playgrounds, or an ad-hoc file:

```bash
cat > /tmp/allowed_channels_check.swift <<'SWIFT'
// Manual sanity check: paste the Update struct excerpt here and verify.
// Not a persistent test; intended to confirm the mapping matches the spec.
struct Update {
    var includePrereleases: Bool
    var allowedChannels: Set<String> {
        includePrereleases ? ["beta"] : []
    }
}
precondition(Update(includePrereleases: false).allowedChannels == [])
precondition(Update(includePrereleases: true).allowedChannels == ["beta"])
print("allowedChannels mapping OK")
SWIFT
swift /tmp/allowed_channels_check.swift
rm /tmp/allowed_channels_check.swift
```

Expected: prints `allowedChannels mapping OK`.

- [ ] **Step 5: Build the full workspace**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: success.

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Update.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift
git commit -m "feat: add Settings.Update model with channel mapping for Sparkle"
```

---

## Task 5: Create `UpdaterService`

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift`

- [ ] **Step 1: Create the file with a compileable skeleton**

```swift
import AppKit
import Sparkle
import RuntimeViewerSettings
import Dependencies
import OSLog

@Loggable(.private)
@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    @Dependency(\.settings) private var settings

    private var updaterController: SPUStandardUpdaterController?
    private var settingsObservationTask: Task<Void, Never>?

    private override init() { super.init() }

    func start() {
        guard updaterController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        updaterController = controller
        installCheckForUpdatesMenuItem(target: controller)
        applyInitialBindings(to: controller.updater)
        startSettingsObservation(for: controller.updater)
        if isDebugBuild {
            #log(.info, "UpdaterService.start() — Debug build detected; initial automatic check suppressed")
            controller.updater.automaticallyChecksForUpdates = false
        }
    }

    func stop() {
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        updaterController = nil
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    var lastUpdateCheckDate: Date? {
        updaterController?.updater.lastUpdateCheckDate
    }

    var isSessionInProgress: Bool {
        updaterController?.updater.sessionInProgress ?? false
    }

    var currentVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Private

    private var isDebugBuild: Bool {
        (Bundle.main.infoDictionary?["CFBundleName"] as? String)?.contains("Debug") == true
    }

    private func installCheckForUpdatesMenuItem(target: SPUStandardUpdaterController) {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        if appMenu.items.contains(where: { $0.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)) }) {
            return
        }
        let aboutIndex = appMenu.items.firstIndex {
            $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        } ?? 0
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = target
        appMenu.insertItem(item, at: aboutIndex + 1)
    }

    private func applyInitialBindings(to updater: SPUUpdater) {
        let update = settings.update
        updater.automaticallyChecksForUpdates = update.automaticallyChecks
        updater.automaticallyDownloadsUpdates = update.automaticallyDownloads
        updater.updateCheckInterval = update.checkInterval.timeInterval
        updater.setAllowedChannels(update.allowedChannels)
    }

    private func startSettingsObservation(for updater: SPUUpdater) {
        // Re-apply Settings.update.* to updater whenever the observable
        // settings snapshot changes.
        settingsObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    _ = withObservationTracking {
                        _ = self?.settings.update
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard let self else { return }
                self.applyInitialBindings(to: updater)
            }
        }
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            settings.update.allowedChannels
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated {
            #log(.error, "Sparkle updater aborted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Build to verify compile**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: success, no warnings. If `@Loggable` expansion or concurrency isolation errors appear, address them by matching `@Loggable` / isolation patterns from the existing `AppDelegate.swift` (which uses `@Loggable(.private)`).

- [ ] **Step 3: Register the file in the Xcode project**

The `App/` group should pick up the new file automatically (pbxproj uses file-system sync for that group). If not, add the file via xcodeproj MCP or drag into Xcode under `RuntimeViewerUsingAppKit/App/`.

Confirm:

```bash
grep UpdaterService.swift RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj | head
```

Expected: at least one reference if the group is not file-system-sync; zero references is fine if the group uses PBXFileSystemSynchronizedRootGroup (check by grep for `PBXFileSystemSynchronizedRootGroup` in pbxproj).

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj/project.pbxproj
git commit -m "feat: add UpdaterService wrapping Sparkle with menu install and Settings binding"
```

---

## Task 6: Wire `UpdaterService` into `AppDelegate`

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift`

- [ ] **Step 1: Add the startup call**

Find `func applicationDidFinishLaunching(_ aNotification: Notification)`. After the existing `MCPService.shared.start(for: AppMCPBridgeDocumentProvider())` line, add:

```swift
        UpdaterService.shared.start()
```

- [ ] **Step 2: Add the teardown call**

Find `func applicationWillTerminate(_ notification: Notification)`. Above the existing `MCPService.shared.stop()` line, add:

```swift
        UpdaterService.shared.stop()
```

- [ ] **Step 3: Verify no new `import Sparkle` was introduced**

```bash
grep -n 'import Sparkle\|SPUUpdater\|SPUStandardUpdaterController' \
  RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift
```

Expected: no matches. All Sparkle types live in `UpdaterService.swift` only.

- [ ] **Step 4: Build and launch**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Launch the built app via Xcode (Run) and confirm:

- No Sparkle update dialog pops up on launch (Debug suppresses initial auto-check).
- The App menu "RuntimeViewer-Debug" has a new "Check for Updates…" item right below "About RuntimeViewer-Debug".
- Clicking "Check for Updates…" opens Sparkle's standard dialog. (It will fail to fetch because `appcast.xml` does not yet exist — expected for this task.)

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/AppDelegate.swift
git commit -m "feat: start and stop UpdaterService from AppDelegate"
```

---

## Task 7: Create `UpdateSettingsView` and register it in `SettingsRootView`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/UpdateSettingsView.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`

- [ ] **Step 1: Inspect the existing style to match**

```bash
cat RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/MCPSettingsView.swift | head -60
```

Note the use of `SettingsForm`, `SettingsSection`, `AppSettings(\.)` property wrapper, the `@Environment(Settings.self)` pattern — match these in the new view.

- [ ] **Step 2: Create `UpdateSettingsView.swift`**

```swift
import SwiftUI
import Dependencies
import RuntimeViewerSettings
import RuntimeViewerUI

public struct UpdateSettingsView: View {
    @Environment(Settings.self)
    private var settings

    @AppSettings(\.update.automaticallyChecks)    private var automaticallyChecks
    @AppSettings(\.update.automaticallyDownloads) private var automaticallyDownloads
    @AppSettings(\.update.checkInterval)          private var checkInterval
    @AppSettings(\.update.includePrereleases)     private var includePrereleases

    @State private var now: Date = .now
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        SettingsForm {
            SettingsSection("Status") {
                LabeledContent("Current Version",
                               value: UpdateStatusReader.currentVersionDisplay())
                LabeledContent("Last Check",
                               value: UpdateStatusReader.lastCheckDisplay(now: now))
                HStack {
                    Spacer()
                    Button("Check Now") {
                        UpdateStatusReader.triggerCheck()
                    }
                    .disabled(UpdateStatusReader.isSessionInProgress())
                }
            }

            SettingsSection("Automatic Checks") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                Picker("Check every", selection: $checkInterval) {
                    ForEach(Settings.CheckInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .disabled(!automaticallyChecks)
            }

            SettingsSection("Installation") {
                Toggle("Automatically download and install updates",
                       isOn: $automaticallyDownloads)
                    .disabled(!automaticallyChecks)
            }

            SettingsSection("Channel") {
                Toggle("Include pre-release versions (Beta)",
                       isOn: $includePrereleases)
                Text("Receive release candidates and beta builds. Pre-releases may contain bugs. Changes apply to the next update check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onReceive(ticker) { now = $0 }
    }
}

/// Module boundary: this type is overridden at the app layer to talk to
/// `UpdaterService`. In the settings package, it provides safe defaults so
/// the view compiles and previews.
public enum UpdateStatusReader {
    public static var currentVersionDisplayProvider: () -> String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    public static var lastCheckDateProvider: () -> Date? = { nil }

    public static var isSessionInProgressProvider: () -> Bool = { false }

    public static var triggerCheckAction: () -> Void = {}

    static func currentVersionDisplay() -> String { currentVersionDisplayProvider() }

    static func lastCheckDisplay(now: Date) -> String {
        guard let date = lastCheckDateProvider() else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func isSessionInProgress() -> Bool { isSessionInProgressProvider() }
    static func triggerCheck() { triggerCheckAction() }
}
```

The `UpdateStatusReader` indirection exists because `RuntimeViewerSettingsUI` cannot depend on `UpdaterService` (which lives in the main app target, not a package). The app wires the providers in Task 8.

- [ ] **Step 3: Register the page in `SettingsRootView`**

Edit `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`. Update the `SettingsPage` enum:

```swift
private enum SettingsPage: String, CaseIterable, Identifiable {
    case general       = "General"
    case notifications = "Notifications"
    case transformer   = "Transformer"
    case mcp           = "MCP"
    case updates       = "Updates"
    case helper        = "Helper"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .transformer: "arrow.triangle.2.circlepath"
        case .mcp: "network"
        case .updates: "arrow.down.circle"
        case .helper: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder
    var contentView: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .notifications: NotificationSettingsView()
        case .transformer: TransformerSettingsView()
        case .mcp: MCPSettingsView()
        case .updates: UpdateSettingsView()
        case .helper: HelperServiceSettingsView()
        }
    }
}
```

- [ ] **Step 4: Build the package**

```bash
cd RuntimeViewerPackages
swift build --target RuntimeViewerSettingsUI 2>&1 | xcsift
cd ..
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/UpdateSettingsView.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift
git commit -m "feat: add Updates settings page with channel and check-interval controls"
```

---

## Task 8: Wire `UpdaterService` providers from the app target

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift`

- [ ] **Step 1: Install providers during `start()`**

Edit `UpdaterService.swift`. Add `import RuntimeViewerSettingsUI` at the top (the module is already a dependency of the app target).

At the end of `start()` (after the `isDebugBuild` block), insert:

```swift
        installSettingsUIProviders()
```

And add this new private method at the bottom of the class:

```swift
    private func installSettingsUIProviders() {
        UpdateStatusReader.currentVersionDisplayProvider = { [weak self] in
            self?.currentVersionDisplay ?? "—"
        }
        UpdateStatusReader.lastCheckDateProvider = { [weak self] in
            self?.lastUpdateCheckDate
        }
        UpdateStatusReader.isSessionInProgressProvider = { [weak self] in
            self?.isSessionInProgress ?? false
        }
        UpdateStatusReader.triggerCheckAction = { [weak self] in
            self?.checkForUpdates()
        }
    }
```

In `stop()`, reset the providers back to defaults so stale closures do not capture a dead service:

```swift
        UpdateStatusReader.currentVersionDisplayProvider = { "—" }
        UpdateStatusReader.lastCheckDateProvider = { nil }
        UpdateStatusReader.isSessionInProgressProvider = { false }
        UpdateStatusReader.triggerCheckAction = {}
```

- [ ] **Step 2: Build the app**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace \
  -scheme "RuntimeViewer macOS" -configuration Debug \
  -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: success.

- [ ] **Step 3: Manual smoke test**

Launch the Debug app and open Settings → Updates. Verify:

- "Current Version" shows something like `2.0.0 (20260421.13.00)` (not `— (—)`).
- "Last Check" shows `Never`.
- Toggles for automatic check / download / include prereleases render and persist across settings close/open.
- Clicking "Check Now" opens the Sparkle standard dialog (it will fail on feed fetch until Task 10 publishes `appcast.xml`; error message is expected).

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/App/UpdaterService.swift
git commit -m "feat: bridge UpdaterService state into UpdateStatusReader for Settings UI"
```

---

## Task 9: Seed `docs/appcast.xml` and enable GitHub Pages

**Files:**
- Create: `docs/appcast.xml`
- Create: `docs/index.html`

- [ ] **Step 1: Create an empty but valid feed**

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>RuntimeViewer</title>
    <link>https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml</link>
    <description>RuntimeViewer release feed</description>
    <language>en</language>
  </channel>
</rss>
```

Write this to `docs/appcast.xml`.

- [ ] **Step 2: Create a minimal `docs/index.html`**

```html
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>RuntimeViewer</title></head>
  <body>
    <h1>RuntimeViewer</h1>
    <p>Release feed: <a href="appcast.xml">appcast.xml</a></p>
    <p>Source: <a href="https://github.com/MxIris-Reverse-Engineering/RuntimeViewer">GitHub</a></p>
  </body>
</html>
```

- [ ] **Step 3: Commit the placeholder feed**

```bash
git add docs/appcast.xml docs/index.html
git commit -m "chore: seed docs/appcast.xml and enable GitHub Pages root"
```

- [ ] **Step 4: Enable GitHub Pages (manual UI step, noted for runbook)**

Go to the GitHub repo → Settings → Pages:

- Source: **Deploy from a branch**
- Branch: `main`, folder `/docs`
- Save

The Pages URL should become `https://mxiris-reverse-engineering.github.io/RuntimeViewer/`. Pages activation for this branch happens after the branch is pushed and merged to `main`. Since this plan works on a feature branch, note this step for post-merge execution (Task 15 re-lists it in the final secrets+pages checklist).

---

## Task 10: Write `ReleaseScript.sh`

**Files:**
- Create: `ReleaseScript.sh` (chmod +x)

- [ ] **Step 1: Create the script with full parameter parsing**

Create `ReleaseScript.sh` at the repo root. The content is large; compose it from the six logical sections below in order. After assembly, `chmod +x ReleaseScript.sh`.

**Section 1 — shebang, strict mode, defaults, helpers:**

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

# Defaults
WORKSPACE="RuntimeViewer-Distribution.xcworkspace"
SCHEME="RuntimeViewer macOS"
CATALYST_SCHEME="RuntimeViewerCatalystHelper"
CONFIGURATION="Release"
BUILD_NUMBER="$(date +"%Y%m%d.%H.%M")"

VERSION_TAG=""
CHANNEL=""
RELEASE_NOTES=""
ED_KEY_FILE=""
UPDATE_APPCAST=false
UPLOAD_TO_GITHUB=false
COMMIT_PUSH=false
INCLUDE_IOS_SIMULATOR=false
SKIP_NOTARIZATION=false
SKIP_OPEN_FINDER=false
KEEP_INTERMEDIATE=false
DRY_RUN=false

NOTARY_PROFILE="notarytool-password"
NOTARY_API_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER_ID=""

FEED_PAGES_URL="https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml"
DOWNLOAD_URL_PREFIX_BASE="https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/download"
RELEASE_NOTES_URL_PREFIX="https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/tag/"

fail() { echo "error: $*" >&2; exit 1; }
log()  { echo "[ReleaseScript] $*"; }
run()  { if $DRY_RUN; then echo "+ $*"; else eval "$@"; fi; }
```

**Section 2 — argument parsing:**

```bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace) WORKSPACE="$2"; shift 2;;
        --scheme) SCHEME="$2"; shift 2;;
        --catalyst-helper-scheme) CATALYST_SCHEME="$2"; shift 2;;
        --configuration) CONFIGURATION="$2"; shift 2;;
        --build-number) BUILD_NUMBER="$2"; shift 2;;
        --version-tag) VERSION_TAG="$2"; shift 2;;
        --channel) CHANNEL="$2"; shift 2;;
        --release-notes) RELEASE_NOTES="$2"; shift 2;;
        --ed-key-file) ED_KEY_FILE="$2"; shift 2;;
        --update-appcast) UPDATE_APPCAST=true; shift;;
        --upload-to-github) UPLOAD_TO_GITHUB=true; shift;;
        --commit-push) COMMIT_PUSH=true; shift;;
        --include-ios-simulator) INCLUDE_IOS_SIMULATOR=true; shift;;
        --skip-notarization) SKIP_NOTARIZATION=true; shift;;
        --skip-open-finder) SKIP_OPEN_FINDER=true; shift;;
        --keep-intermediate) KEEP_INTERMEDIATE=true; shift;;
        --dry-run) DRY_RUN=true; shift;;
        --notary-profile) NOTARY_PROFILE="$2"; shift 2;;
        --notary-api-key) NOTARY_API_KEY="$2"; shift 2;;
        --notary-key-id) NOTARY_KEY_ID="$2"; shift 2;;
        --notary-issuer-id) NOTARY_ISSUER_ID="$2"; shift 2;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^#//'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done

if $UPLOAD_TO_GITHUB || $UPDATE_APPCAST || $COMMIT_PUSH; then
    [[ -z "$VERSION_TAG" ]] && fail "--version-tag required when --upload-to-github / --update-appcast / --commit-push is set"
fi

if [[ -z "$CHANNEL" && -n "$VERSION_TAG" ]]; then
    case "$VERSION_TAG" in
        *-RC*|*-beta*|*-alpha*) CHANNEL="beta";;
        v[0-9]*) CHANNEL="stable";;
        *) fail "cannot infer channel from tag '$VERSION_TAG'; pass --channel explicitly";;
    esac
fi

if ! $SKIP_NOTARIZATION; then
    if [[ -n "$NOTARY_API_KEY" ]]; then
        [[ -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] \
            || fail "--notary-api-key requires --notary-key-id and --notary-issuer-id"
    fi
fi

log "workspace=$WORKSPACE scheme=$SCHEME configuration=$CONFIGURATION build=$BUILD_NUMBER"
log "version_tag=${VERSION_TAG:-<none>} channel=${CHANNEL:-<none>}"
log "update_appcast=$UPDATE_APPCAST upload_to_github=$UPLOAD_TO_GITHUB commit_push=$COMMIT_PUSH"
```

**Section 3 — archive, export, notarize:**

```bash
BUILD_PATH="$PROJECT_DIR/Products/Archives"
EXPORT_PATH="$BUILD_PATH/Products/Export"
CATALYST_EXPORT_PATH="$PROJECT_DIR/RuntimeViewerUsingAppKit"
CATALYST_HELPER_ARCHIVE="$BUILD_PATH/RuntimeViewerCatalystHelper.xcarchive"
MAIN_ARCHIVE="$BUILD_PATH/RuntimeViewer.xcarchive"

mkdir -p "$BUILD_PATH"

log "Archiving Catalyst helper"
run xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$CATALYST_SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "| xcbeautify"

run rm -rf "$CATALYST_EXPORT_PATH/RuntimeViewerCatalystHelper.app"
run xcodebuild -exportArchive \
    -archivePath "$CATALYST_HELPER_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$CATALYST_EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig-Catalyst.plist" \
    -quiet
run rm -f "$CATALYST_EXPORT_PATH/Packaging.log" \
        "$CATALYST_EXPORT_PATH/DistributionSummary.plist" \
        "$CATALYST_EXPORT_PATH/ExportOptions.plist"

log "Archiving main app"
run xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$MAIN_ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
    "| xcbeautify"

run rm -rf "$EXPORT_PATH"
run xcodebuild -exportArchive \
    -archivePath "$MAIN_ARCHIVE" \
    -configuration "$CONFIGURATION" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$PROJECT_DIR/ArchiveExportConfig.plist" \
    -quiet

APP_PATH=$(find "$EXPORT_PATH" -maxdepth 1 -type d -name '*.app' | head -1)
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || fail "expected exported *.app under $EXPORT_PATH"

if ! $SKIP_NOTARIZATION; then
    log "Notarizing"
    NOTARIZE_ZIP="$EXPORT_PATH/RuntimeViewer-notarize.zip"
    run /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
    if [[ -n "$NOTARY_API_KEY" ]]; then
        run xcrun notarytool submit "$NOTARIZE_ZIP" \
            --key "$NOTARY_API_KEY" --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" --wait
    else
        run xcrun notarytool submit "$NOTARIZE_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" --wait
    fi
    run xcrun stapler staple "$APP_PATH"
    run rm -f "$NOTARIZE_ZIP"
fi
```

**Section 4 — iOS Simulator (optional):**

```bash
IOS_SIM_ZIP=""
if $INCLUDE_IOS_SIMULATOR; then
    log "Building iOS Simulator app"
    DERIVED="$PROJECT_DIR/DerivedData"
    run xcodebuild build \
        -workspace "$WORKSPACE" \
        -scheme "RuntimeViewer iOS" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED" \
        -skipPackagePluginValidation -skipMacroValidation \
        CODE_SIGNING_ALLOWED=NO

    IOS_APP="$DERIVED/Build/Products/${CONFIGURATION}-iphonesimulator/RuntimeViewer.app"
    IOS_SIM_ZIP="$PROJECT_DIR/RuntimeViewer-iOS-Simulator.zip"
    [[ -d "$IOS_APP" ]] || fail "iOS Simulator app missing at $IOS_APP"
    ( cd "$(dirname "$IOS_APP")" && /usr/bin/ditto -c -k --keepParent "RuntimeViewer.app" "$IOS_SIM_ZIP" )
fi
```

**Section 5 — zip + appcast + upload + commit:**

```bash
log "Packaging macOS zip"
MAC_ZIP="$PROJECT_DIR/RuntimeViewer-macOS.zip"
run rm -f "$MAC_ZIP"
run /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$MAC_ZIP"

if $UPDATE_APPCAST; then
    STAGING="$PROJECT_DIR/.release-staging"
    run rm -rf "$STAGING"
    run mkdir -p "$STAGING"
    run cp "$MAC_ZIP" "$STAGING/"

    APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"
    [[ -f "$APPCAST_PATH" ]] || fail "docs/appcast.xml missing; run Task 9 first"

    DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX_BASE}/${VERSION_TAG}/"

    GENERATE_APPCAST_ARGS=(
        "$STAGING"
        --appcast-file "$APPCAST_PATH"
        -o "$APPCAST_PATH"
        --download-url-prefix "$DOWNLOAD_URL_PREFIX"
        --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX"
    )
    if [[ -n "$ED_KEY_FILE" ]]; then
        GENERATE_APPCAST_ARGS+=(--ed-key-file "$ED_KEY_FILE")
    fi
    if [[ "$CHANNEL" == "beta" ]]; then
        GENERATE_APPCAST_ARGS+=(--channel beta)
    fi

    log "Running generate_appcast"
    run generate_appcast "${GENERATE_APPCAST_ARGS[@]}"

    if ! $KEEP_INTERMEDIATE; then
        run rm -rf "$STAGING"
    fi
fi

if $UPLOAD_TO_GITHUB; then
    log "Uploading GitHub Release"
    GH_ARGS=(release create "$VERSION_TAG" \
        --title "RuntimeViewer $VERSION_TAG")
    [[ "$CHANNEL" == "beta" ]] && GH_ARGS+=(--prerelease)
    if [[ -n "$RELEASE_NOTES" && -f "$RELEASE_NOTES" ]]; then
        GH_ARGS+=(--notes-file "$RELEASE_NOTES")
    else
        GH_ARGS+=(--generate-notes)
    fi
    GH_ARGS+=("$MAC_ZIP")
    [[ -n "$IOS_SIM_ZIP" ]] && GH_ARGS+=("$IOS_SIM_ZIP")

    if ! $DRY_RUN && gh release view "$VERSION_TAG" >/dev/null 2>&1; then
        log "Release $VERSION_TAG exists; uploading assets with --clobber"
        ASSETS=("$MAC_ZIP")
        [[ -n "$IOS_SIM_ZIP" ]] && ASSETS+=("$IOS_SIM_ZIP")
        run gh release upload "$VERSION_TAG" --clobber "${ASSETS[@]}"
    else
        run gh "${GH_ARGS[@]}"
    fi
fi

if $COMMIT_PUSH; then
    log "Committing docs/appcast.xml"
    if ! $DRY_RUN && git diff --quiet docs/appcast.xml; then
        log "docs/appcast.xml unchanged; nothing to commit"
    else
        run git add docs/appcast.xml
        run git commit -m "chore: update appcast for $VERSION_TAG"
        run git push origin HEAD
    fi
fi
```

**Section 6 — finale:**

```bash
if ! $SKIP_OPEN_FINDER; then
    run open "$EXPORT_PATH"
fi

log "Done. Outputs:"
log "  macOS zip:           $MAC_ZIP"
[[ -n "$IOS_SIM_ZIP" ]] && log "  iOS Simulator zip:   $IOS_SIM_ZIP"
$UPDATE_APPCAST && log "  appcast:             $PROJECT_DIR/docs/appcast.xml"
```

- [ ] **Step 2: Make executable and sanity-check with --help / --dry-run**

```bash
chmod +x ReleaseScript.sh
./ReleaseScript.sh --help || true
./ReleaseScript.sh --dry-run --version-tag v2.1.0-RC.1 \
    --release-notes Changelogs/v2.0.0.md --update-appcast \
    --skip-notarization --skip-open-finder --configuration Debug 2>&1 | head -40
```

Expected: the dry-run prints the archive and generate_appcast commands without executing them; channel is inferred as `beta`.

- [ ] **Step 3: Commit**

```bash
git add ReleaseScript.sh
git commit -m "feat: add ReleaseScript.sh unifying archive, notarize, appcast, and release"
```

---

## Task 11: Local dry-run of `ReleaseScript.sh` (build + appcast only)

This task validates the script produces a valid Sparkle-signed archive and updates `docs/appcast.xml` correctly. It does **not** upload to GitHub and does **not** test the end-to-end "old app consumes appcast → upgrades" flow (deferred to Task 16, which runs against a real RC after merge — doing it locally requires mismatched bundle IDs between Debug and Release to align, which is fragile).

- [ ] **Step 1: Run the script in Release configuration with notarization skipped**

```bash
./ReleaseScript.sh --version-tag v2.1.0-dryrun \
    --channel beta --update-appcast \
    --skip-notarization --skip-open-finder 2>&1 | xcsift
```

Expected outputs:

- `RuntimeViewer-macOS.zip` at the repo root.
- `Products/Archives/Products/Export/RuntimeViewer.app` (Release configuration → product name `RuntimeViewer.app`; notarization is skipped so the bundle is not stapled, which is fine for this task).
- `docs/appcast.xml` has exactly one new `<item>` at the top with:
  - `<sparkle:channel>beta</sparkle:channel>`
  - `<sparkle:version>` equal to `CURRENT_PROJECT_VERSION` at run time (YYYYMMDD.HH.MM).
  - `<enclosure sparkle:edSignature="..." length="..." ...>` pointing at `https://github.com/MxIris-Reverse-Engineering/RuntimeViewer/releases/download/v2.1.0-dryrun/RuntimeViewer-macOS.zip`.

- [ ] **Step 2: Manually verify the EdDSA signature**

```bash
/tmp/Sparkle-unpacked/bin/sign_update RuntimeViewer-macOS.zip
# Prints something like:
#   sparkle:edSignature="abc...==" length="12345678"
grep -A0 'sparkle:edSignature' docs/appcast.xml | head -3
```

Expected: the signature in the appcast matches the one printed by `sign_update`.

- [ ] **Step 3: Confirm channel semantics**

```bash
xmllint --xpath 'count(//channel/item[1]/*[local-name()="channel"])' docs/appcast.xml
# Expected: 1 (the new beta item has a <sparkle:channel> tag).

xmllint --xpath 'string(//channel/item[1]/*[local-name()="channel"])' docs/appcast.xml
# Expected: beta
```

- [ ] **Step 4: Confirm pre-existing `<item>`s were preserved (if any existed)**

If `docs/appcast.xml` already had prior items before the dry-run, verify they remain:

```bash
xmllint --xpath 'count(//channel/item)' docs/appcast.xml
```

Expected: at least 1 (the dry-run item), and equal to (prior count + 1).

- [ ] **Step 5: Clean up**

```bash
git restore docs/appcast.xml
rm -f RuntimeViewer-macOS.zip
rm -rf Products/Archives
git status
```

Expected: working tree is clean (only the committed source).

- [ ] **Step 6: No commit**

This task is validation-only. Record Step 1–4 outcomes verbatim in the PR description when opening the PR.

---

## Task 12: Slim the CI workflow to invoke `ReleaseScript.sh`

**Files:**
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Replace the current workflow file**

Overwrite `.github/workflows/release.yml` with the following slimmed structure (~90 lines):

```yaml
name: Build & Release

on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Tag to release (e.g. v2.1.0 or v2.1.0-RC.1)'
        required: true
        type: string
      channel:
        description: 'Release channel (leave empty to infer from tag)'
        type: choice
        default: ''
        options: ['', stable, beta]
      runner:
        description: 'Runner to use'
        type: choice
        default: 'macos-latest'
        options: [macos-latest, self-hosted]
      create_release:
        description: 'Create GitHub Release and update appcast'
        type: boolean
        default: true

jobs:
  release:
    runs-on: ${{ inputs.runner || 'macos-latest' }}
    permissions:
      contents: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          ref: ${{ inputs.tag || github.ref }}
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Clone sibling dependencies
        run: |
          cd ..
          for repo in MachOKit MachOObjCSection MachOSwiftSection; do
            rm -rf "$repo"
            git clone --depth 1 "https://github.com/MxIris-Reverse-Engineering/${repo}.git"
          done

      - name: Select Xcode 26.2
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '26.2'

      - name: Import code signing certificates
        env:
          DEVELOPER_ID_P12: ${{ secrets.DEVELOPER_ID_P12 }}
          DEVELOPER_ID_PASSWORD: ${{ secrets.DEVELOPER_ID_PASSWORD }}
          MAC_DEVELOPMENT_P12: ${{ secrets.MAC_DEVELOPMENT_P12 }}
          MAC_DEVELOPMENT_PASSWORD: ${{ secrets.MAC_DEVELOPMENT_PASSWORD }}
        run: |
          KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
          KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          echo "$DEVELOPER_ID_P12" | base64 --decode > "$RUNNER_TEMP/developer_id.p12"
          security import "$RUNNER_TEMP/developer_id.p12" -P "$DEVELOPER_ID_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
          echo "$MAC_DEVELOPMENT_P12" | base64 --decode > "$RUNNER_TEMP/mac_development.p12"
          security import "$RUNNER_TEMP/mac_development.p12" -P "$MAC_DEVELOPMENT_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
          for cert_url in https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer; do
            cert_file="$RUNNER_TEMP/$(basename "$cert_url")"
            curl -sL "$cert_url" -o "$cert_file"
            security import "$cert_file" -k "$KEYCHAIN_PATH" -T /usr/bin/codesign || true
          done
          security list-keychain -d user -s "$KEYCHAIN_PATH" $(security list-keychain -d user | tr -d '"')
          security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

      - name: Decode notary API key
        env:
          NOTARY_AUTH_KEY: ${{ secrets.NOTARY_AUTH_KEY }}
          NOTARY_KEY_ID:   ${{ secrets.NOTARY_KEY_ID }}
        run: |
          mkdir -p "$RUNNER_TEMP/notary_keys/private_keys"
          echo "$NOTARY_AUTH_KEY" | base64 --decode > "$RUNNER_TEMP/notary_keys/private_keys/AuthKey_${NOTARY_KEY_ID}.p8"
          echo "NOTARY_KEY_FILE=$RUNNER_TEMP/notary_keys/private_keys/AuthKey_${NOTARY_KEY_ID}.p8" >> $GITHUB_ENV

      - name: Decode Sparkle EdDSA private key
        env:
          SPARKLE_EDDSA_PRIVATE_KEY: ${{ secrets.SPARKLE_EDDSA_PRIVATE_KEY }}
        run: |
          echo "$SPARKLE_EDDSA_PRIVATE_KEY" | base64 --decode > "$RUNNER_TEMP/sparkle_ed25519_priv.pem"
          echo "SPARKLE_ED_KEY_FILE=$RUNNER_TEMP/sparkle_ed25519_priv.pem" >> $GITHUB_ENV

      - name: Configure git author for docs push
        if: ${{ inputs.create_release == true || github.event_name == 'push' }}
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

      - name: Install Sparkle tools
        run: |
          curl -L -o /tmp/Sparkle.tar.xz \
            "https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-2.6.0.tar.xz"
          mkdir -p "$RUNNER_TEMP/Sparkle"
          tar -xf /tmp/Sparkle.tar.xz -C "$RUNNER_TEMP/Sparkle"
          echo "$RUNNER_TEMP/Sparkle/bin" >> $GITHUB_PATH

      - name: Run ReleaseScript
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          TAG="${{ inputs.tag || github.ref_name }}"
          CHANNEL="${{ inputs.channel }}"
          CHANGELOG_FILE="Changelogs/${TAG}.md"
          RELEASE_NOTES_ARG=()
          [[ -f "$CHANGELOG_FILE" ]] && RELEASE_NOTES_ARG=(--release-notes "$CHANGELOG_FILE")

          CHANNEL_ARG=()
          [[ -n "$CHANNEL" ]] && CHANNEL_ARG=(--channel "$CHANNEL")

          CREATE_FLAGS=()
          if [[ "${{ inputs.create_release }}" == "true" || "${{ github.event_name }}" == "push" ]]; then
            CREATE_FLAGS=(--update-appcast --upload-to-github --commit-push)
          fi

          ./ReleaseScript.sh \
            --notary-api-key "$NOTARY_KEY_FILE" \
            --notary-key-id "${{ secrets.NOTARY_KEY_ID }}" \
            --notary-issuer-id "${{ secrets.NOTARY_ISSUER_ID }}" \
            --version-tag "$TAG" \
            --ed-key-file "$SPARKLE_ED_KEY_FILE" \
            --include-ios-simulator \
            --skip-open-finder \
            "${CHANNEL_ARG[@]}" \
            "${CREATE_FLAGS[@]}" \
            "${RELEASE_NOTES_ARG[@]}"

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: release-artifacts
          path: |
            RuntimeViewer-macOS.zip
            RuntimeViewer-iOS-Simulator.zip

      - name: Clean up keychain
        if: always()
        run: |
          if [ -f "$RUNNER_TEMP/app-signing.keychain-db" ]; then
            security delete-keychain "$RUNNER_TEMP/app-signing.keychain-db"
          fi
```

- [ ] **Step 2: Lint the YAML**

```bash
yamllint -d '{extends: default, rules: {line-length: {max: 200}}}' .github/workflows/release.yml || true
# yamllint may not be installed; if not, skip. Alternatively use actionlint:
actionlint .github/workflows/release.yml || true
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: slim release workflow to invoke ReleaseScript.sh"
```

---

## Task 13: Remove `ArchiveScript.sh`

**Files:**
- Delete: `ArchiveScript.sh`

- [ ] **Step 1: Verify it is unreferenced**

```bash
grep -rn "ArchiveScript.sh" --include='*.md' --include='*.yml' --include='*.sh' \
  --include='*.swift' 2>/dev/null
```

Expected: only `README.md` and `CLAUDE.md` references remain; those are updated in Task 14. If other references exist, stop and update them before deletion.

- [ ] **Step 2: Delete the file**

```bash
git rm ArchiveScript.sh
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: remove ArchiveScript.sh in favor of ReleaseScript.sh"
```

---

## Task 14: Update `README.md` and `CLAUDE.md`

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add an "Updates" section to `README.md`**

Insert after the existing `## Getting Started` section (or in whichever position matches the document flow):

```markdown
### Updates

RuntimeViewer uses [Sparkle](https://sparkle-project.org/) for automatic updates.

- The app checks for updates once a day by default. You can adjust the
  interval or disable automatic checks in **Settings → Updates**.
- To try pre-release builds, enable **Settings → Updates → Include
  pre-release versions (Beta)**. RC and beta builds are delivered through
  the same feed on an opt-in channel.
- You can always run a manual check from **RuntimeViewer → Check for Updates…**.
- Release feed: `https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml`.
```

- [ ] **Step 2: Update `CLAUDE.md` Build Commands**

Find the `## Build Commands` section. Replace the lines that reference `ArchiveScript.sh` with references to `ReleaseScript.sh`. Specifically:

- Change `./ArchiveScript.sh` → `./ReleaseScript.sh` (local build).
- Change the short description from "builds Catalyst helper first, then main app, with notarization" to "archives, notarizes, and optionally generates appcast + uploads GitHub Release".
- Append a brief note: "Use `./ReleaseScript.sh --update-appcast --upload-to-github --commit-push --version-tag vX.Y.Z` to cut a full release; omit those flags to only produce the local signed zip."

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: document auto-updates for users and replace ArchiveScript references"
```

---

## Task 15: Configure GitHub secrets, Pages, and branch policy (manual)

This task is a manual configuration checklist performed in the GitHub web UI. No commits.

- [ ] **Step 1: Add the Sparkle secret**

Go to the repo → Settings → Secrets and variables → Actions → New repository secret:

- Name: `SPARKLE_EDDSA_PRIVATE_KEY`
- Value: paste the base64 string copied in Task 1 Step 4.

Confirm the secret appears in the list (value is masked).

- [ ] **Step 2: Enable GitHub Pages**

Go to Settings → Pages:

- Source: **Deploy from a branch**
- Branch: `main`, folder `/docs`
- Save.

Note: Pages activation requires `docs/appcast.xml` and `docs/index.html` to exist on the selected branch. They exist on the feature branch now; after this branch merges to `main`, Pages serves them. For the first merge, Pages propagation may take up to 10 minutes.

- [ ] **Step 3: Verify workflow permissions**

Settings → Actions → General → Workflow permissions → **Read and write permissions** (so the CI step `--commit-push` can push `docs/appcast.xml`). Save.

- [ ] **Step 4: Record completion in the PR description**

When opening the PR for this branch, the description must list:

- [x] SPARKLE_EDDSA_PRIVATE_KEY secret configured
- [x] GitHub Pages enabled (main / /docs)
- [x] Workflow permissions set to read+write

---

## Task 16: End-to-end post-merge trial release (after PR merges)

This task executes *after* the feature branch is merged to `main`. It validates the entire pipeline with a genuine beta release.

- [ ] **Step 1: Pick a safe beta version**

Pick the next patch version with an `-RC.1` suffix, e.g. `v2.0.1-RC.1`. Add a `Changelogs/v2.0.1-RC.1.md` describing only "Auto-update support via Sparkle" and minor fixes.

- [ ] **Step 2: Tag and push**

```bash
git checkout main && git pull
git tag -a v2.0.1-RC.1 -m "v2.0.1 Release Candidate 1: auto-update via Sparkle"
git push origin v2.0.1-RC.1
```

Expected: the `release.yml` workflow starts automatically.

- [ ] **Step 3: Monitor CI**

```bash
gh run watch
```

Expected: the workflow succeeds; `docs/appcast.xml` gains a new `<item>` with `<sparkle:channel>beta</sparkle:channel>`; the GitHub Release for `v2.0.1-RC.1` is created and marked as pre-release; `RuntimeViewer-macOS.zip` and `RuntimeViewer-iOS-Simulator.zip` are attached.

- [ ] **Step 4: Verify Pages serves the updated feed**

```bash
curl -s https://mxiris-reverse-engineering.github.io/RuntimeViewer/appcast.xml \
  | grep -E 'sparkle:channel|v2\.0\.1-RC\.1'
```

Expected: includes the new entry with beta channel. Pages may take a few minutes to propagate.

- [ ] **Step 5: Install a previous stable and opt into beta**

Install `v2.0.0` (stable) from its GitHub Release. Launch it, go to Settings → Updates, enable **Include pre-release versions (Beta)**, then click **Check Now**. Sparkle should offer the `v2.0.1-RC.1` build with working EdDSA verification. Accept, install, and confirm the new version launches.

- [ ] **Step 6: Record results**

Update the PR description (or follow-up issue) with:

- Beta propagation time.
- Observed update flow duration.
- Any UI oddities (expected: none).

- [ ] **Step 7: Promote to stable when satisfied**

After the RC has been running for at least 3 days on beta users with no regressions:

```bash
git tag -a v2.0.1 -m "v2.0.1: auto-update via Sparkle"
git push origin v2.0.1
```

Confirm the new stable release lands, Pages updates `appcast.xml`, and default-channel users receive it.

---

## Appendix: Dependencies between tasks

- Task 1 unlocks Task 3 (public key) and Task 15 (CI secret).
- Task 2 (Sparkle SPM) must precede Task 5 (UpdaterService imports Sparkle).
- Task 4 (Settings.Update model) must precede Tasks 5, 7, 8 (all consume the model).
- Task 7 (UpdateSettingsView + SettingsRootView) must precede Task 8 (app wires providers into `UpdateStatusReader` from SettingsUI).
- Task 9 (seed docs/appcast.xml) must precede Tasks 11, 12, 16 (appcast mutations assume the file exists).
- Task 10 (ReleaseScript.sh) must precede Task 11 (script execution) and Task 12 (CI invokes it).
- Task 13 (delete ArchiveScript.sh) must follow Task 12 (CI no longer references it).
- Tasks 14 (docs update) and 15 (GitHub configuration) can run in parallel with each other, anywhere after Task 13.
- Task 16 runs only after PR merge.

## Appendix: Rollback procedure during implementation

If at any point the feature branch becomes unbuildable:

```bash
git log --oneline main..HEAD        # list feature-branch commits
git reset --hard <last-good-sha>    # destructive; coordinate with user first
```

Prefer small reverts over wholesale resets. If only one task broke, `git revert <sha>` the specific commit and retry that task.
