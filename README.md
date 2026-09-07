# FrameGrab

A small native macOS app that turns a slice of a video into an **image
sequence** — so you can hand still frames to an LLM (Claude, etc.) that can't
accept video input.

**The workflow it's built for:** you find a video of a UI online and want to
rebuild it (e.g. as a Framer component). Describing motion in words is hard, and
most LLMs don't take video. Instead, drop the clip in here, select the part you
care about, and export it as frames you can paste into a chat or study yourself.

![Reference look](https://placeholder.invalid) <!-- the UI mirrors a dark editor: preview + timeline + export panel -->

## Features

- **Open / drag-and-drop** a video (`.mp4`, `.mov`, `.m4v`).
- **Preview + scrub** with a clean player (no clutter controls).
- **Timeline with a draggable in/out region** over a thumbnail filmstrip.
- **Pick frames two ways:** a fixed **FPS** rate, or an exact **count** of
  evenly-spaced frames. Both are **typable** — use the presets and the stepper,
  or click the field and enter any number (1–2000 frames, 0.5–30 fps).
- **PNG or JPG** (with quality), optional **downscale** (≤1280 / 960 / 640px).
- **Live estimate** of how many images you'll get, with a gentle nudge when you
  exceed the ~20-image sweet spot for LLMs.
- **Name the export** yourself — the **Name** field sets the `.zip` filename or
  the folder name (it defaults to the video's own name).
- **Export as a `.zip`** (default) or as loose files in a folder; the result is
  revealed in Finder when done. Export shows progress and can be cancelled.

Everything runs **100% locally** — no video ever leaves your Mac.

## Two builds

| | This app (`Sources/`) | [`desktop/`](desktop/README.md) |
|---|---|---|
| Platforms | macOS 13+ | **Windows**, macOS, Linux |
| Built with | SwiftUI + AVFoundation | Tauri (Rust + web) |
| Decoding | AVFoundation | ffmpeg |
| `.webm` / `.mkv` | Not supported | **Supported** |
| Auto-update | Sparkle | Not yet |

Both have the same editor and the same export options. The Swift app is the
more native-feeling Mac build and updates itself; the Tauri one is what runs on
Windows. Everything below describes the Swift app — for the cross-platform one,
see **[desktop/README.md](desktop/README.md)**.

## Requirements

- macOS **13.0 (Ventura)** or newer.
- **Xcode 15+** *or* the Command Line Tools (for the Swift toolchain) — only
  needed to build; the produced `.app` runs on any macOS 13+ machine.

## Run it

### Option A — open in Xcode (easiest)

1. `open Package.swift` (or open this folder in Xcode 15+).
2. Pick the **FrameGrab** scheme.
3. Press **⌘R**.

### Option B — from the terminal

```bash
swift run
```

### Build a quick local app (no auto-update)

```bash
./make_app.sh
```

This produces a `FrameGrab.app` straight from the Swift Package — handy for
running it yourself. Because the build is unsigned/ad-hoc, the **first** launch
needs a right-click → **Open** to get past Gatekeeper (after that, double-click
works normally). This build does **not** include auto-update or the app icon
(the icon needs the Xcode build; see below).

### Install it into /Applications (recommended for daily use)

```bash
./scripts/install.sh
```

Builds the app and installs it to `/Applications`, replacing any older copy and
relaunching it. Run this again any time you pull new changes — it's the
"update my app" command. No Gatekeeper prompt, because a locally-built app
isn't quarantined.

### App icon

The icon is generated on your Mac (no extra tools) into the asset catalog:

```bash
swift scripts/make_icon.swift
```

That writes a clean built-in icon. To use **your own** design, drop a
1024×1024 PNG at `Branding/icon-1024.png` and re-run the command. The icon shows
in the Xcode build, the DMG, the Dock and Finder. (`release.sh` runs this for you
if the icon is missing.)

### Share it + auto-update (DMG + Sparkle)

To hand the app to someone else and have it update itself, build through the
Xcode project (which embeds the [Sparkle](https://sparkle-project.org) updater)
and publish to GitHub Releases:

```bash
brew install xcodegen
xcodegen generate
SPARKLE_BIN=/path/to/Sparkle/bin ./scripts/release.sh
```

Full step-by-step (signing keys, first-time setup, publishing, and your friend's
one-time Gatekeeper bypass) is in **[DISTRIBUTION.md](DISTRIBUTION.md)**.

## How to use

1. Drop a video onto the window (or **File ▸ Open Video…**, ⌘O).
2. Scrub to find the moment you want. Click the timeline to move the playhead.
3. Drag the two green handles to set the in/out region — or move the playhead
   and click **Set In** / **Set Out**. **Reset** selects the whole clip.
4. In the right panel choose **FPS** or **Count**. Tap a preset, use the
   stepper/slider, or click into the number and type an exact value (press
   **Return** to apply). Pick the format/scale, and ZIP or folder output. Watch
   the **≈ N images** estimate.
5. Type a **Name** for the export if you want one — leave it blank to use the
   video's name. The caption underneath shows exactly what will be created.
6. Click **Export** and pick where to save. The frames appear in Finder when
   done.

Frames are named `frame_0001.<ext>`, `frame_0002.<ext>`, … in order, inside a
`.zip` or folder named after the **Name** field. A folder export never writes
into an existing folder — if the name is taken you get `My name 2`, `My name 3`,
and so on, so nothing of yours is overwritten.

## Notes & limitations

- **This app is macOS only.** It's native SwiftUI/AVFoundation and can't be
  cross-compiled. For Windows (and Linux) there is a separate Tauri build in
  [`desktop/`](desktop/README.md) with the same feature set — see
  [Two builds](#two-builds) above.
- **`.webm` isn't supported** — macOS/AVFoundation can't read it. Convert to
  `.mp4`/`.mov` first (e.g. `ffmpeg -i in.webm out.mp4`).
- The app is **not sandboxed** (it's a personal local tool) and **not notarized**.
  To distribute it more widely you'd enable App Sandbox + sign and notarize it;
  none of that is required to use it yourself.

## Project layout

```
Package.swift                      Swift Package — quick `swift run` dev build
project.yml                        XcodeGen spec — Xcode app w/ Sparkle (releases)
Support/Info.plist                 App metadata + icon + Sparkle auto-update keys
Assets.xcassets/AppIcon.appiconset App icon set (PNGs generated by make_icon.swift)
make_app.sh                        Quick local .app (no auto-update)
scripts/make_icon.swift            Generate the app icon (or scale Branding/icon-1024.png)
scripts/make_dmg.sh                App → styled drag-to-Applications DMG
scripts/release.sh                 Build + DMG + signed appcast → GitHub release
DISTRIBUTION.md                    Full DMG + auto-update setup guide
desktop/                           Cross-platform (Windows/macOS/Linux) Tauri build
Sources/FrameGrab/
  FrameGrabApp.swift               App entry + menu commands (+ updater, Help link)
  Updater.swift                    Sparkle "Check for Updates" (compiled w/ Sparkle)
  EditorModel.swift                State: player, selection, settings, export
  Models/ExportSettings.swift      Frame/format/scale/output options + limits
  Models/ExportNaming.swift        Export-name sanitising + non-colliding folders
  Services/VideoLoader.swift       Async metadata + timeline thumbnails
  Services/FrameExporter.swift     Frame extraction + zipping
  Views/ContentView.swift          Layout, empty state, drag & drop
  Views/PlayerView.swift           AVPlayerLayer preview + transport
  Views/TimelineView.swift         Filmstrip + in/out handles + playhead
  Views/ExportPanelView.swift      Settings + export button + progress
  Theme.swift                      Palette + timecode formatting
```

## Possible next steps

- Contact-sheet / grid export and copy-to-clipboard (paste one image into a chat).
- Multiple saved regions.
- `.webm` support (the `desktop/` build already has it, via ffmpeg).
- Developer ID signing + notarization (zero-warning install for anyone).
- Auto-update and a signed installer for the `desktop/` build.
