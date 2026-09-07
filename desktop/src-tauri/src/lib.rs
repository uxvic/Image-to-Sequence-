//! The desktop shell: a thin command layer over `framegrab-core`.
//!
//! Everything with real logic in it — which frames to sample, what to call the
//! export, how to phrase an ffmpeg command — lives in the core crate, where it
//! is unit-tested. What is left here is process spawning, progress events and
//! file dialogs, which is the part that genuinely differs per platform.

mod export;
mod tools;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use base64::Engine;
use framegrab_core::ffmpeg::{self, VideoInfo};
use framegrab_core::naming;
use tauri::{AppHandle, Emitter, Manager, State};

use export::{ExportRequest, OutputMode};
use tools::{command, ToolStatus, Tools};

/// Shown whenever ffmpeg can't be found. Written once, so the wording stays the
/// same wherever the user runs into it.
pub const MISSING_FFMPEG: &str =
    "FrameGrab needs ffmpeg to read video. Install it (macOS: `brew install ffmpeg`, \
     Windows: `winget install Gyan.FFmpeg`), or put ffmpeg and ffprobe next to the app, \
     then reopen FrameGrab.";

/// Names each thumbnail run's scratch directory. It must be unique across
/// *every* run, not just within a channel: the filmstrip and a fallback still
/// are rendered at the same time, and sharing a directory means one finishing
/// deletes the other's frames out from under it.
static SCRATCH_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
struct AppState {
    export_cancel: Arc<AtomicBool>,
    /// The newest request token per thumbnail channel, so results for a video
    /// the user has already moved on from are dropped instead of drawn. Keyed
    /// by channel because the filmstrip and the preview grid render at the same
    /// time and must not cancel each other.
    thumbnail_tokens: Arc<Mutex<HashMap<String, u64>>>,
}

impl AppState {
    /// Claims the channel for a new request and returns its token.
    fn next_thumbnail_token(&self, channel: &str) -> u64 {
        let mut tokens = self.thumbnail_tokens.lock().expect("thumbnail tokens poisoned");
        let token = tokens.entry(channel.to_string()).or_insert(0);
        *token += 1;
        *token
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ExportOutcome {
    path: String,
    cancelled: bool,
}

#[tauri::command]
fn check_tools() -> ToolStatus {
    Tools::status()
}

#[tauri::command]
fn probe_video(path: String) -> Result<VideoInfo, String> {
    let tools = Tools::locate().ok_or_else(|| MISSING_FFMPEG.to_string())?;
    let output = command(&tools.ffprobe)
        .args(ffmpeg::probe_args(&path))
        .output()
        .map_err(|e| format!("Couldn't run ffprobe: {e}"))?;

    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr);
        let detail = detail.lines().last().unwrap_or("ffprobe reported no detail");
        return Err(format!("Couldn't open that video: {detail}"));
    }
    ffmpeg::parse_probe(&String::from_utf8_lossy(&output.stdout))
}

/// The name the export falls back to when the user hasn't typed one.
#[tauri::command]
fn default_export_name(path: String) -> String {
    naming::default_name_for(&PathBuf::from(path))
}

/// The name the export will really use, once the typed text has been trimmed
/// and stripped of characters some file system would reject.
#[tauri::command]
fn resolve_export_name(typed: String, fallback: String) -> String {
    naming::sanitize(&typed, &fallback)
}

/// Renders thumbnails in the background, emitting each one as it appears so the
/// filmstrip and the preview grid fill in progressively.
#[tauri::command]
fn render_thumbnails(
    app: AppHandle,
    state: State<'_, AppState>,
    channel: String,
    path: String,
    times: Vec<f64>,
    max_width: u32,
) -> u64 {
    let token = state.next_thumbnail_token(&channel);
    let tokens = state.thumbnail_tokens.clone();
    let is_current = move |channel: &str| {
        tokens
            .lock()
            .map(|t| t.get(channel).copied() == Some(token))
            .unwrap_or(false)
    };

    std::thread::spawn(move || {
        let Some(tools) = Tools::locate() else { return };
        let run = SCRATCH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        // Built from a counter rather than from `channel`, which is caller
        // input and has no business shaping a path this code later deletes.
        let scratch = std::env::temp_dir().join(format!("framegrab-thumbs-{}-{run}", std::process::id()));
        if std::fs::create_dir_all(&scratch).is_err() {
            return;
        }

        for (index, seconds) in times.iter().enumerate() {
            // The user has moved on — stop rendering for a screen nobody is
            // looking at any more.
            if !is_current(&channel) {
                break;
            }
            let file = scratch.join(format!("{index}.jpg"));
            let args = ffmpeg::thumbnail_args(&path, *seconds, &file.to_string_lossy(), max_width);
            let ran = command(&tools.ffmpeg).args(&args).output();
            if ran.map(|r| !r.status.success()).unwrap_or(true) {
                continue;
            }
            let Ok(bytes) = std::fs::read(&file) else { continue };
            let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);

            let _ = app.emit(
                &channel,
                serde_json::json!({
                    "token": token,
                    "index": index,
                    "dataUrl": format!("data:image/jpeg;base64,{encoded}"),
                }),
            );
        }

        let _ = std::fs::remove_dir_all(&scratch);
        if is_current(&channel) {
            let _ = app.emit(&channel, serde_json::json!({ "token": token, "done": true }));
        }
    });

    token
}

/// Abandons whatever is still rendering on a channel — the token moves on, so
/// the running thread stops at its next frame.
#[tauri::command]
fn cancel_thumbnails(state: State<'_, AppState>, channel: String) {
    state.next_thumbnail_token(&channel);
}

#[tauri::command]
async fn export_frames(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ExportRequest,
) -> Result<ExportOutcome, String> {
    let cancel = state.export_cancel.clone();
    cancel.store(false, Ordering::SeqCst);

    let handle = app.clone();
    let outcome = tauri::async_runtime::spawn_blocking(move || {
        export::run(request, cancel, |done, total| {
            let _ = handle.emit(
                "export-progress",
                serde_json::json!({ "done": done, "total": total }),
            );
        })
    })
    .await
    .map_err(|e| format!("The export stopped unexpectedly: {e}"))?;

    match outcome {
        Ok(result) => Ok(ExportOutcome {
            path: result.path.display().to_string(),
            cancelled: false,
        }),
        Err(message) if message == export::CANCELLED => Ok(ExportOutcome {
            path: String::new(),
            cancelled: true,
        }),
        Err(message) => Err(message),
    }
}

#[tauri::command]
fn cancel_export(state: State<'_, AppState>) {
    state.export_cancel.store(true, Ordering::SeqCst);
}

/// Shows the finished export in Finder / File Explorer.
#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    app.opener()
        .reveal_item_in_dir(PathBuf::from(path))
        .map_err(|e| format!("Couldn't show that in the file manager: {e}"))
}

/// Which output the export dialog should ask for.
#[tauri::command]
fn output_modes() -> Vec<OutputMode> {
    vec![OutputMode::Zip, OutputMode::Folder]
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            app.manage(AppState::default());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            check_tools,
            probe_video,
            default_export_name,
            resolve_export_name,
            render_thumbnails,
            cancel_thumbnails,
            export_frames,
            cancel_export,
            reveal,
            output_modes,
        ])
        .run(tauri::generate_context!())
        .expect("error while running FrameGrab");
}
