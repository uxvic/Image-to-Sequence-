# FrameGrab for Windows, macOS and Linux

The cross-platform build of FrameGrab: the same video-to-image-sequence editor
as the macOS app in the repository root, rebuilt on [Tauri](https://tauri.app)
so it runs as a real installed app on Windows too.

The macOS Swift app in `../Sources` still works and is unchanged. This is the
build that gets you a Windows `.exe`; keep whichever suits you until this one
has some real mileage on your machines.

## What's the same, and what's different

Same editor, same feature set: open or drop a video, scrub, drag the in/out
handles, pick frames by **FPS** or **Count** (both typable), preview the exact
frames and click any of them to leave it out, then export **PNG** or **JPG**
into a **ZIP** or a **folder** with a name you choose.

| | macOS app (Swift) | This app (Tauri) |
|---|---|---|
| Decoding | AVFoundation | ffmpeg |
| `.webm` / `.mkv` | Not supported | **Supported** |
| Auto-update | Sparkle | Not yet |
| Windows | — | Yes |

Everything still runs **100% locally** — ffmpeg is a local process, and no
video ever leaves your machine.

## Requirements

**ffmpeg and ffprobe** must be available. FrameGrab looks in three places, in
order:

1. `FRAMEGRAB_FFMPEG_DIR`, if you've set it.
2. Next to the FrameGrab executable (`Contents/Resources` inside a `.app`).
3. Your `PATH`.

Install it once and you're done:

```bash
# macOS
brew install ffmpeg
# Windows
winget install Gyan.FFmpeg
# Debian/Ubuntu
sudo apt install ffmpeg
```

The app shows a banner with these instructions if it can't find them, and a
**Check again** button so you don't have to restart after installing.

To build from source you also need [Rust](https://rustup.rs), Node 18+, and
Tauri's own platform prerequisites (Visual Studio Build Tools + WebView2 on
Windows, Xcode Command Line Tools on macOS, `libwebkit2gtk-4.1-dev` on Linux) —
see [Tauri's prerequisites](https://tauri.app/start/prerequisites/).

## Run it

```bash
cd desktop
npm install
npm run dev
```

## Build an installer

```bash
npm run build
```

Output lands in `src-tauri/target/release/bundle/` — `.msi`/`.exe` on Windows,
`.dmg`/`.app` on macOS, `.deb`/`.AppImage` on Linux. Cross-compiling isn't
practical: build each platform's installer on that platform (or in CI).

Before a **release** build, generate the full icon set — the bundlers need
`.ico` on Windows and `.icns` on macOS, which aren't committed:

```bash
npm run icon                       # regenerate the source PNGs
npx tauri icon src-tauri/icons/icon.png
```

Then add the generated `icons/icon.ico` and `icons/icon.icns` to the `icon`
array in `src-tauri/tauri.conf.json`. `npm run dev` and Linux builds work
without this step.

## Tests

```bash
npm test
```

Two suites, both fast and both offline:

- `cargo test` over `core/` — the frame maths, the export-name rules and the
  ffmpeg command building. The core crate has no Tauri dependency precisely so
  these run on any machine, including one without the WebKit headers.
- `node --test` over `tests/` — the JavaScript copy of the frame maths that
  drives the live estimate. It asserts the *same table of cases* as the Rust
  tests, so the two can't quietly drift apart.

## Layout

```
core/                     Platform-independent logic (unit-tested)
  src/frames.rs           Which timestamps get sampled
  src/naming.rs           Export-name rules + non-colliding folders
  src/ffmpeg.rs           ffmpeg/ffprobe argument building + probe parsing
src-tauri/                The desktop shell
  src/lib.rs              Tauri commands, thumbnail streaming, progress events
  src/export.rs           Frame writing, zipping, safe cleanup
  src/tools.rs            Finding ffmpeg/ffprobe
  tauri.conf.json         Window, security policy, bundle settings
src/                      The window itself (no build step, no framework)
  index.html              Structure
  styles.css              The macOS app's palette, as CSS variables
  app.js                  State, rendering and wiring
  frames.js               The frame maths, mirrored from core/src/frames.rs
tests/                    JavaScript tests
scripts/make_icon.mjs     Draws the app icon straight to PNG
```

## Notes

- **One ffmpeg call per frame.** Simple, cancellable, and it keeps the exported
  frames exactly matching the previewed ones (including your exclusions). A
  12–24 frame export is near-instant; a 2000-frame one takes a while and shows
  progress throughout.
- **Playback vs. export.** The preview player uses the system webview, which
  handles H.264 MP4/MOV everywhere but may refuse HEVC or ProRes. When it does,
  the window falls back to scrubbing through ffmpeg-rendered stills — export is
  unaffected either way, because export never uses the webview.
- **`assetProtocol.scope` is `**`** in `tauri.conf.json`. It has to be: you
  choose the video, so the app can't know the path in advance. The scope only
  governs what the window may *read* for playback.
- **Not signed or notarised.** Same as the macOS app — fine for personal use,
  but Windows SmartScreen and macOS Gatekeeper will warn on first run.
