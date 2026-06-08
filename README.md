# Image to Sequence

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
  evenly-spaced frames.
- **PNG or JPG** (with quality), optional **downscale** (≤1280 / 960 / 640px).
- **Live estimate** of how many images you'll get, with a gentle nudge when you
  exceed the ~20-image sweet spot for LLMs.
- **Export as a `.zip`** (default) or as loose files in a folder; the result is
  revealed in Finder when done. Export shows progress and can be cancelled.

Everything runs **100% locally** — no video ever leaves your Mac.

## Requirements

- macOS **13.0 (Ventura)** or newer.
- **Xcode 15+** *or* the Command Line Tools (for the Swift toolchain) — only
  needed to build; the produced `.app` runs on any macOS 13+ machine.

## Run it

### Option A — open in Xcode (easiest)

1. `open Package.swift` (or open this folder in Xcode 15+).
2. Pick the **ImageToSequence** scheme.
3. Press **⌘R**.

### Option B — from the terminal

```bash
swift run
```

### Build a double-clickable app

```bash
./make_app.sh
```

This produces `ImageToSequence.app`. Drag it to `/Applications`. Because the
build is unsigned/ad-hoc, the **first** launch needs a right-click → **Open** to
get past Gatekeeper (after that, double-click works normally).

## How to use

1. Drop a video onto the window (or **File ▸ Open Video…**, ⌘O).
2. Scrub to find the moment you want. Click the timeline to move the playhead.
3. Drag the two green handles to set the in/out region — or move the playhead
   and click **Set In** / **Set Out**. **Reset** selects the whole clip.
4. In the right panel choose **FPS** or **Count**, the format/scale, and ZIP or
   folder output. Watch the **≈ N images** estimate.
5. Click **Export** and pick where to save. The frames appear in Finder when
   done.

Frames are named `frame_0001.<ext>`, `frame_0002.<ext>`, … in order.

## Notes & limitations

- **`.webm` isn't supported** — macOS/AVFoundation can't read it. Convert to
  `.mp4`/`.mov` first (e.g. `ffmpeg -i in.webm out.mp4`).
- The app is **not sandboxed** (it's a personal local tool) and **not notarized**.
  To distribute it more widely you'd enable App Sandbox + sign and notarize it;
  none of that is required to use it yourself.

## Project layout

```
Package.swift                      Swift Package (executable target)
make_app.sh                        Package the release binary into a .app
Sources/ImageToSequence/
  ImageToSequenceApp.swift         App entry + menu commands
  EditorModel.swift                State: player, selection, settings, export
  Models/ExportSettings.swift      Frame/format/scale/output options
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
- `.webm` support (would require bundling ffmpeg).
- App icon, signing, notarization.
