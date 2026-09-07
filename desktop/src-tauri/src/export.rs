//! Running the export: one ffmpeg call per frame, then either a folder of
//! images or a single `.zip`.
//!
//! The safety rules here mirror the macOS app's, for the same reason: an
//! export that fails or is cancelled must never take a file the user already
//! had with it.

use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use framegrab_core::ffmpeg::{extract_args, frame_file_name, ExtractOptions, VideoInfo};
use framegrab_core::naming;
use zip::write::SimpleFileOptions;

use crate::tools::{command, Tools};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OutputMode {
    /// Bundle every frame into a single `.zip`.
    Zip,
    /// Write loose image files into a folder.
    Folder,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportRequest {
    pub input: String,
    /// The exact timestamps to sample, in order — already filtered by whatever
    /// the user excluded in the preview grid, so this list *is* the export.
    pub times: Vec<f64>,
    pub source: VideoInfo,
    pub options: ExtractOptions,
    pub output_mode: OutputMode,
    /// A `.zip` path for zip exports, or the chosen parent folder otherwise.
    pub destination: String,
    /// The sanitised export name, used for the folder and the archive's
    /// top-level directory.
    pub name: String,
}

pub struct Outcome {
    /// What to reveal in Finder/Explorer once the export finishes.
    pub path: PathBuf,
}

pub fn run(
    request: ExportRequest,
    cancel: Arc<AtomicBool>,
    mut progress: impl FnMut(usize, usize),
) -> Result<Outcome, String> {
    if request.times.is_empty() {
        return Err("There are no frames to export for the selected range.".into());
    }
    let tools = Tools::locate().ok_or_else(|| crate::MISSING_FFMPEG.to_string())?;

    let name = naming::sanitize(&request.name, "frames");
    let destination = Path::new(&request.destination);

    // Where the frames are actually written, and whether this export owns that
    // path (and may therefore delete it if things go wrong).
    let (write_dir, final_path, staging_root, owns_final) = match request.output_mode {
        OutputMode::Folder => {
            // Never an existing folder: frames are not mixed into someone
            // else's, and cleanup can only remove what this export created.
            let dir = naming::unique_folder(destination, &name);
            (dir.clone(), dir, None, true)
        }
        OutputMode::Zip => {
            let parent = destination
                .parent()
                .ok_or_else(|| "That save location isn't a folder.".to_string())?;
            // Stage inside the destination folder so the final step is a rename
            // on the same volume, which either happens or doesn't.
            let staging = naming::unique_folder(parent, &format!(".{name}.framegrab-part"));
            let write_dir = staging.join(&name);
            let owns_final = !destination.exists();
            (write_dir, destination.to_path_buf(), Some(staging), owns_final)
        }
    };

    let result = write_frames(&request, &tools, &write_dir, &cancel, &mut progress).and_then(|_| {
        if let Some(staging) = &staging_root {
            let archive = staging.join("archive.zip");
            zip_folder(&write_dir, &name, &archive)?;
            replace(&archive, &final_path)?;
        }
        Ok(())
    });

    // The staging area is scratch space either way.
    if let Some(staging) = &staging_root {
        let _ = fs::remove_dir_all(staging);
    }

    match result {
        Ok(()) => Ok(Outcome { path: final_path }),
        Err(error) => {
            if owns_final && final_path.exists() {
                let _ = remove_any(&final_path);
            }
            Err(error)
        }
    }
}

fn write_frames(
    request: &ExportRequest,
    tools: &Tools,
    write_dir: &Path,
    cancel: &AtomicBool,
    progress: &mut impl FnMut(usize, usize),
) -> Result<(), String> {
    fs::create_dir_all(write_dir).map_err(|e| format!("Couldn't create the export folder: {e}"))?;

    let total = request.times.len();
    // The last sample can land exactly on the end of the clip, where there is
    // no frame to decode. Stay a hair inside it, as the macOS app does.
    let last_usable = (request.source.duration - 1.0 / 600.0).max(0.0);

    for (index, seconds) in request.times.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            return Err(CANCELLED.to_string());
        }

        let clamped = seconds.clamp(0.0, last_usable);
        let file_name = frame_file_name(index, total, request.options.format);
        let output = write_dir.join(&file_name);
        let args = extract_args(
            &request.input,
            clamped,
            &output.to_string_lossy(),
            request.source,
            request.options,
        );

        let result = command(&tools.ffmpeg)
            .args(&args)
            .output()
            .map_err(|e| format!("Couldn't run ffmpeg: {e}"))?;

        if !result.status.success() || !output.is_file() {
            let detail = String::from_utf8_lossy(&result.stderr);
            let detail = detail.lines().last().unwrap_or("ffmpeg reported no detail");
            return Err(format!("Frame {} couldn't be read from the video: {detail}", index + 1));
        }

        progress(index + 1, total);
    }
    Ok(())
}

/// Packs `folder` into `archive`, with everything under a single top-level
/// directory so unzipping produces one tidy folder rather than loose frames.
fn zip_folder(folder: &Path, top_level: &str, archive: &Path) -> Result<(), String> {
    let file = File::create(archive).map_err(|e| format!("Couldn't create the archive: {e}"))?;
    let mut writer = zip::ZipWriter::new(file);
    let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    writer
        .add_directory(format!("{top_level}/"), options)
        .map_err(|e| format!("Couldn't create the archive: {e}"))?;

    let mut entries: Vec<PathBuf> = fs::read_dir(folder)
        .map_err(|e| format!("Couldn't read the exported frames: {e}"))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file())
        .collect();
    // Frames go into the archive in the order they were captured.
    entries.sort();

    for path in entries {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| "A frame has an unreadable file name.".to_string())?;
        writer
            .start_file(format!("{top_level}/{name}"), options)
            .map_err(|e| format!("Couldn't add {name} to the archive: {e}"))?;
        let mut source = File::open(&path).map_err(|e| format!("Couldn't read {name}: {e}"))?;
        io::copy(&mut source, &mut writer).map_err(|e| format!("Couldn't add {name}: {e}"))?;
    }

    writer.finish().map_err(|e| format!("Couldn't finish the archive: {e}"))?;
    Ok(())
}

/// Moves `source` onto `destination`, replacing it only once the new file is
/// complete. Falls back to a copy when the two are on different volumes.
fn replace(source: &Path, destination: &Path) -> Result<(), String> {
    if destination.exists() {
        remove_any(destination)?;
    }
    if fs::rename(source, destination).is_ok() {
        return Ok(());
    }
    fs::copy(source, destination)
        .map(|_| ())
        .map_err(|e| format!("Couldn't save the archive: {e}"))
}

fn remove_any(path: &Path) -> Result<(), String> {
    let result = if path.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    result.map_err(|e| format!("Couldn't replace {}: {e}", path.display()))
}

/// Sentinel the command layer turns into "cancelled" rather than an error
/// dialog — the user asked for this one.
pub const CANCELLED: &str = "framegrab:cancelled";
