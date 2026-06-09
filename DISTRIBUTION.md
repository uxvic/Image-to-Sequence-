# Distributing FrameGrab (DMG + Sparkle auto-update)

This sets up a **free, unsigned** distribution with **automatic updates** via
[Sparkle](https://sparkle-project.org). You publish releases to **GitHub
Releases**; installed copies (yours and your friend's) update themselves.

> **Unsigned reality check:** because the app isn't notarized by Apple (that
> needs the $99/yr Developer Program), the **first** install on any Mac shows a
> Gatekeeper warning that must be bypassed once (see *Your friend's first
> install* below). After that, Sparkle updates are automatic.

---

## One-time setup (on your Mac)

**1. Install the tooling**
```bash
brew install xcodegen          # generates the Xcode project from project.yml
brew install create-dmg        # optional: styled DMG window (falls back to plain)
brew install gh                # optional: auto-publishes GitHub releases
```

**2. Get Sparkle's command-line tools**
Download the latest `Sparkle-x.y.z.tar.xz` from
<https://github.com/sparkle-project/Sparkle/releases>, unpack it, and note the
`bin/` folder (it contains `generate_keys`, `generate_appcast`, `sign_update`).
You'll pass it as `SPARKLE_BIN` later.

**3. Create your update-signing keys (EdDSA)**
```bash
/path/to/Sparkle/bin/generate_keys
```
- It stores the **private** key in your login Keychain.
- It prints a **public** key string. Copy it.

> ⚠️ **Back up the private key** — losing it means you can never sign updates
> again (users would be stuck). Export a backup and store it safely:
> ```bash
> /path/to/Sparkle/bin/generate_keys -x sparkle_private_key.backup
> ```

**4. Paste the public key into the app**
Open `Support/Info.plist` and replace the `SUPublicEDKey` value
(`REPLACE_WITH_YOUR_SPARKLE_PUBLIC_KEY`) with the public key from step 3.

**5. Confirm the feed URL**
`SUFeedURL` in `Support/Info.plist` is already set to:
```
https://github.com/uxvic/Image-to-Sequence-/releases/latest/download/appcast.xml
```
Change `uxvic/Image-to-Sequence-` only if your repo path differs.

**6. Generate the icon, the project, and test once**
```bash
swift scripts/make_icon.swift   # writes the app-icon PNGs (once)
xcodegen generate
open FrameGrab.xcodeproj         # then press ⌘R to run
```
To use your **own** icon instead of the built-in one, drop a 1024×1024 PNG at
`Branding/icon-1024.png` and re-run `swift scripts/make_icon.swift`.

---

## Publishing a release

**1. Bump the version** in `project.yml` (both numbers — Sparkle compares
`CURRENT_PROJECT_VERSION`):
```yaml
MARKETING_VERSION: "1.1"      # human-facing version
CURRENT_PROJECT_VERSION: "2"  # must increase every release
```

**2. Build, package, sign, and publish**
```bash
SPARKLE_BIN=/path/to/Sparkle/bin ./scripts/release.sh
```
This will:
- regenerate the project and build a Release `.app`,
- make `FrameGrab.dmg` (human download) + `FrameGrab.zip` (Sparkle),
- generate and **sign** `appcast.xml`,
- create/update the GitHub release `vX.Y` with those three files (if `gh` is
  installed; otherwise it prints manual upload steps).

That's it — anyone running the app will be offered the update automatically
(or via **FrameGrab ▸ Check for Updates…**).

---

## Your friend's first install

1. Open the GitHub release page and download **`FrameGrab.dmg`**.
2. Open the DMG, drag **FrameGrab** to **Applications**.
3. First launch only: **right-click the app → Open → Open** (or, if macOS still
   blocks it, **System Settings ▸ Privacy & Security ▸ Open Anyway**). This is
   the one-time unsigned-app bypass.
4. Done. Future versions update automatically in the background.

---

## How the pieces fit

| File | Role |
|------|------|
| `project.yml` | XcodeGen spec → `FrameGrab.xcodeproj` (embeds + signs Sparkle) |
| `Support/Info.plist` | App metadata + Sparkle keys (`SUFeedURL`, `SUPublicEDKey`) |
| `Sources/.../Updater.swift` | Sparkle "Check for Updates" UI (compiled only with Sparkle) |
| `scripts/make_dmg.sh` | App → drag-to-Applications DMG |
| `scripts/release.sh` | Full build → DMG + zip + signed appcast → GitHub release |

The plain `Package.swift` still works for quick development
(`swift run`) — it just doesn't include auto-update.

## Troubleshooting

- **`generate_appcast not found`** → pass `SPARKLE_BIN=/path/to/Sparkle/bin`.
- **Updates not detected** → confirm you bumped `CURRENT_PROJECT_VERSION`, that
  the release is marked *latest* (not pre-release), and that `appcast.xml` +
  `FrameGrab.zip` are both attached to the release.
- **Sparkle framework didn't embed** (crash on launch about `Sparkle`) → in
  Xcode, select the target ▸ *General* ▸ *Frameworks, Libraries, and Embedded
  Content* ▸ set **Sparkle** to **Embed & Sign**, then rebuild.
- **macOS 27 beta quirks** → notarization/Gatekeeper behavior on the beta can be
  stricter; the right-click→Open / "Open Anyway" path still applies.
