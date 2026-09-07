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

#[derive(Debug)]
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
    // The last sample routinely lands on the very end of the clip, which is
    // past the point where any frame starts. `last_decodable_time` backs off
    // to the final frame instead.
    let last_usable = request.source.last_decodable_time();

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

        let mut result = command(&tools.ffmpeg)
            .args(&args)
            .output()
            .map_err(|e| format!("Couldn't run ffmpeg: {e}"))?;

        // A variable-rate clip can still have no frame at the time asked for.
        // One step back is enough to land on the previous one; anything worse
        // than that is a real problem worth reporting.
        if !result.status.success() || !output.is_file() {
            let step_back = (clamped - 1.0 / request.source.frame_rate.max(1.0)).max(0.0);
            let retry = extract_args(
                &request.input,
                step_back,
                &output.to_string_lossy(),
                request.source,
                request.options,
            );
            result = command(&tools.ffmpeg)
                .args(&retry)
                .output()
                .map_err(|e| format!("Couldn't run ffmpeg: {e}"))?;
        }

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

#[cfg(test)]
mod tests {
    use super::*;
    use framegrab_core::ffmpeg::ImageFormat;
    use std::io::Read;
    use std::time::{SystemTime, UNIX_EPOCH};

    /// A scratch directory nobody else is using.
    fn scratch(label: &str) -> PathBuf {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("framegrab-{label}-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Synthesises a two-second clip. Returns `None` when ffmpeg isn't
    /// installed, so these tests skip rather than fail on a bare machine.
    fn make_clip(dir: &Path) -> Option<(String, VideoInfo)> {
        let tools = Tools::locate()?;
        let path = dir.join("clip.mp4");
        let ok = command(&tools.ffmpeg)
            .args([
                "-y", "-loglevel", "error", "-f", "lavfi", "-i",
                "testsrc=duration=2:size=320x180:rate=10", "-pix_fmt", "yuv420p",
            ])
            .arg(&path)
            .status()
            .ok()?
            .success();
        if !ok {
            return None;
        }
        Some((
            path.to_string_lossy().into_owned(),
            VideoInfo { duration: 2.0, width: 320, height: 180, frame_rate: 10.0 },
        ))
    }

    fn request(input: &str, source: VideoInfo, mode: OutputMode, destination: &Path, name: &str) -> ExportRequest {
        ExportRequest {
            input: input.to_string(),
            times: vec![0.0, 0.5, 1.0, 2.0],
            source,
            options: ExtractOptions { format: ImageFormat::Png, jpeg_quality: 0.9, max_width: None },
            output_mode: mode,
            destination: destination.to_string_lossy().into_owned(),
            name: name.to_string(),
        }
    }

    fn live() -> Arc<AtomicBool> {
        Arc::new(AtomicBool::new(false))
    }

    #[test]
    fn a_folder_export_writes_every_frame_in_order() {
        let dir = scratch("folder");
        let Some((input, source)) = make_clip(&dir) else { return };

        let outcome = run(
            request(&input, source, OutputMode::Folder, &dir, "My Shots"),
            live(),
            |_, _| {},
        )
        .unwrap();

        assert_eq!(outcome.path, dir.join("My Shots"));
        let mut names: Vec<String> = fs::read_dir(&outcome.path)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, ["frame_0001.png", "frame_0002.png", "frame_0003.png", "frame_0004.png"]);
        // Real images, not empty files.
        assert!(names.iter().all(|n| fs::metadata(outcome.path.join(n)).unwrap().len() > 100));

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_second_export_never_writes_into_the_first_ones_folder() {
        let dir = scratch("collide");
        let Some((input, source)) = make_clip(&dir) else { return };

        let first = run(request(&input, source, OutputMode::Folder, &dir, "Shots"), live(), |_, _| {}).unwrap();
        // Something of the user's, which must survive.
        fs::write(first.path.join("notes.txt"), "keep me").unwrap();

        let second = run(request(&input, source, OutputMode::Folder, &dir, "Shots"), live(), |_, _| {}).unwrap();

        assert_eq!(second.path, dir.join("Shots 2"));
        assert!(first.path.join("notes.txt").exists());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_zip_export_holds_the_frames_under_one_named_folder() {
        let dir = scratch("zip");
        let Some((input, source)) = make_clip(&dir) else { return };
        let archive = dir.join("out.zip");

        let outcome = run(
            request(&input, source, OutputMode::Zip, &archive, "Reel"),
            live(),
            |_, _| {},
        )
        .unwrap();

        assert_eq!(outcome.path, archive);
        let mut zip = zip::ZipArchive::new(File::open(&archive).unwrap()).unwrap();
        let names: Vec<String> = zip.file_names().map(str::to_string).collect();
        assert!(names.contains(&"Reel/frame_0001.png".to_string()), "{names:?}");
        assert_eq!(names.iter().filter(|n| n.ends_with(".png")).count(), 4);

        // And the bytes really are a PNG.
        {
            let mut entry = zip.by_name("Reel/frame_0001.png").unwrap();
            let mut header = [0u8; 8];
            entry.read_exact(&mut header).unwrap();
            assert_eq!(header, [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
        }

        // Nothing is left behind next to the archive.
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains("framegrab-part"))
            .collect();
        assert!(leftovers.is_empty(), "staging left behind: {leftovers:?}");

        drop(zip);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn cancelling_leaves_the_archive_it_would_have_replaced_alone() {
        let dir = scratch("cancel");
        let Some((input, source)) = make_clip(&dir) else { return };
        let archive = dir.join("existing.zip");
        fs::write(&archive, b"the user's previous export").unwrap();

        let cancel = Arc::new(AtomicBool::new(true));
        let error = run(
            request(&input, source, OutputMode::Zip, &archive, "Reel"),
            cancel,
            |_, _| {},
        )
        .unwrap_err();

        assert_eq!(error, CANCELLED);
        assert_eq!(fs::read(&archive).unwrap(), b"the user's previous export");

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn cancelling_a_folder_export_removes_only_what_it_created() {
        let dir = scratch("cancel-folder");
        let Some((input, source)) = make_clip(&dir) else { return };

        let cancel = Arc::new(AtomicBool::new(true));
        let error = run(
            request(&input, source, OutputMode::Folder, &dir, "Shots"),
            cancel,
            |_, _| {},
        )
        .unwrap_err();

        assert_eq!(error, CANCELLED);
        assert!(!dir.join("Shots").exists());
        // The folder the user picked is untouched.
        assert!(dir.join("clip.mp4").exists());

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn progress_is_reported_once_per_frame() {
        let dir = scratch("progress");
        let Some((input, source)) = make_clip(&dir) else { return };

        let mut seen = Vec::new();
        run(
            request(&input, source, OutputMode::Folder, &dir, "Shots"),
            live(),
            |done, total| seen.push((done, total)),
        )
        .unwrap();

        assert_eq!(seen, vec![(1, 4), (2, 4), (3, 4), (4, 4)]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_request_deserialises_from_the_shape_the_window_sends() {
        // Guards the IPC contract: the window builds this JSON by hand, so a
        // renamed field here would silently stop reaching the exporter.
        let json = r#"{
            "input": "/v/clip.mp4",
            "times": [0.0, 1.0],
            "source": {"duration": 2.0, "width": 320, "height": 180, "frameRate": 30.0},
            "options": {"format": "jpeg", "jpegQuality": 0.8, "maxWidth": 640},
            "outputMode": "folder",
            "destination": "/out",
            "name": "Shots"
        }"#;
        let request: ExportRequest = serde_json::from_str(json).unwrap();
        assert_eq!(request.output_mode, OutputMode::Folder);
        assert_eq!(request.options.max_width, Some(640));
        assert_eq!(request.source.frame_rate, 30.0);
        assert_eq!(request.times.len(), 2);

        // And the zip form, with "Original" scale sent as null.
        let json = json
            .replace(r#""folder""#, r#""zip""#)
            .replace(r#""maxWidth": 640"#, r#""maxWidth": null"#);
        let request: ExportRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(request.output_mode, OutputMode::Zip);
        assert_eq!(request.options.max_width, None);
    }

    #[test]
    fn an_empty_frame_list_is_refused_before_anything_is_created() {
        let dir = scratch("empty");
        let mut req = request("/nonexistent.mp4", VideoInfo { duration: 1.0, width: 320, height: 180, frame_rate: 30.0 }, OutputMode::Folder, &dir, "Shots");
        req.times.clear();

        assert!(run(req, live(), |_, _| {}).is_err());
        assert!(!dir.join("Shots").exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
