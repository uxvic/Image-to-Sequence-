//! Building the ffmpeg/ffprobe command lines and reading their output back.
//!
//! Only the argument vectors and the parsing live here — nothing is spawned —
//! so the exact command the app will run is something a test can assert on.

use serde::{Deserialize, Serialize};

/// Output image format for each exported frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ImageFormat {
    Png,
    Jpeg,
}

impl ImageFormat {
    pub fn extension(self) -> &'static str {
        match self {
            ImageFormat::Png => "png",
            ImageFormat::Jpeg => "jpg",
        }
    }
}

/// What a single frame extraction should produce.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractOptions {
    pub format: ImageFormat,
    /// 0.1–1.0, matching the macOS app's Quality slider. Ignored for PNG.
    pub jpeg_quality: f64,
    /// Longest edge-to-be, in pixels, or `None` to keep the source resolution.
    #[serde(default)]
    pub max_width: Option<u32>,
}

impl Default for ExtractOptions {
    fn default() -> Self {
        Self { format: ImageFormat::Png, jpeg_quality: 0.9, max_width: None }
    }
}

/// A clip's display geometry, length and nominal rate, as reported by ffprobe.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoInfo {
    pub duration: f64,
    /// Width **after** any rotation metadata is applied, so it matches what the
    /// player and the extracted frames actually show.
    pub width: u32,
    pub height: u32,
    /// Nominal frames per second. Only used to work out where the last
    /// decodable frame is; a missing or nonsense value falls back to 30.
    #[serde(default = "default_frame_rate")]
    pub frame_rate: f64,
}

fn default_frame_rate() -> f64 {
    30.0
}

impl VideoInfo {
    /// The latest timestamp that still has a frame behind it.
    ///
    /// A clip's last frame *starts* one frame-length before the clip ends, and
    /// ffmpeg's accurate seek returns the first frame at or after the time
    /// asked for — so asking for anything past that start point decodes
    /// nothing at all and the export fails on its final frame. Backing off by
    /// one frame (plus a hair, against floating-point drift) lands on it.
    pub fn last_decodable_time(&self) -> f64 {
        if !self.duration.is_finite() || self.duration <= 0.0 {
            return 0.0;
        }
        let rate = if self.frame_rate.is_finite() && self.frame_rate >= 1.0 {
            self.frame_rate
        } else {
            default_frame_rate()
        };
        (self.duration - 1.0 / rate - 1e-4).max(0.0)
    }
}

pub fn probe_args(input: &str) -> Vec<String> {
    [
        "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-select_streams",
        "v:0", input,
    ]
    .iter()
    .map(|s| (*s).to_string())
    .collect()
}

/// Reads ffprobe's JSON. Returns a message rather than a typed error because
/// the only consumer is a dialog the user reads.
pub fn parse_probe(json: &str) -> Result<VideoInfo, String> {
    let root: serde_json::Value =
        serde_json::from_str(json).map_err(|e| format!("Couldn't read the video's details: {e}"))?;

    let stream = root
        .get("streams")
        .and_then(|s| s.as_array())
        .and_then(|s| s.first())
        .ok_or_else(|| "That file has no video track.".to_string())?;

    let width = stream.get("width").and_then(serde_json::Value::as_u64).unwrap_or(0) as u32;
    let height = stream.get("height").and_then(serde_json::Value::as_u64).unwrap_or(0) as u32;
    if width == 0 || height == 0 {
        return Err("That file has no video track.".to_string());
    }

    // ffmpeg auto-rotates the frames it writes, but still reports the stored
    // (pre-rotation) size — so a portrait phone clip would come back as
    // landscape unless the same swap is applied here.
    let (width, height) = if rotation_swaps_axes(stream) { (height, width) } else { (width, height) };

    let duration = read_duration(root.get("format"))
        .or_else(|| read_duration(Some(stream)))
        .filter(|d| d.is_finite() && *d > 0.0)
        .ok_or_else(|| "Couldn't work out how long that video is.".to_string())?;

    let frame_rate = read_rational(stream, "avg_frame_rate")
        .or_else(|| read_rational(stream, "r_frame_rate"))
        .filter(|r| r.is_finite() && *r >= 1.0)
        .unwrap_or_else(default_frame_rate);

    Ok(VideoInfo { duration, width, height, frame_rate })
}

/// ffprobe reports rates as `"30/1"` — and as `"0/0"` when it doesn't know.
fn read_rational(stream: &serde_json::Value, key: &str) -> Option<f64> {
    let text = stream.get(key)?.as_str()?;
    let (num, den) = text.split_once('/')?;
    let den: f64 = den.parse().ok()?;
    if den == 0.0 {
        return None;
    }
    Some(num.parse::<f64>().ok()? / den)
}

fn read_duration(node: Option<&serde_json::Value>) -> Option<f64> {
    let value = node?.get("duration")?;
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse::<f64>().ok()))
}

fn rotation_swaps_axes(stream: &serde_json::Value) -> bool {
    // Modern ffprobe reports rotation in side_data_list; older files carry a
    // `tags.rotate` string. Both appear in the wild, so read both.
    let from_side_data = stream
        .get("side_data_list")
        .and_then(|l| l.as_array())
        .and_then(|list| list.iter().find_map(|entry| entry.get("rotation")?.as_f64()));

    let from_tags = stream
        .get("tags")
        .and_then(|t| t.get("rotate"))
        .and_then(|r| r.as_str().and_then(|s| s.parse::<f64>().ok()).or_else(|| r.as_f64()));

    let rotation = from_side_data.or(from_tags).unwrap_or(0.0);
    let normalized = rotation.abs().rem_euclid(180.0);
    (normalized - 90.0).abs() < 1.0
}

/// The size a frame should be written at, or `None` to leave it alone.
///
/// Never upscales: asking for "≤ 1280px" from a 640px-wide clip returns `None`
/// so the frame keeps its own resolution.
pub fn scaled_size(source: VideoInfo, max_width: Option<u32>) -> Option<(u32, u32)> {
    let max_width = max_width?;
    if source.width == 0 || source.height == 0 || max_width >= source.width {
        return None;
    }
    let scale = f64::from(max_width) / f64::from(source.width);
    // ffmpeg's encoders want even dimensions; rounding to an even number also
    // keeps the aspect ratio visually identical.
    let height = ((f64::from(source.height) * scale).round() as u32).max(2) & !1;
    Some((max_width & !1, height))
}

/// ffmpeg's JPEG quality scale runs 2 (best) to 31 (worst) — the inverse of the
/// app's 0.1–1.0 slider.
pub fn jpeg_qscale(quality: f64) -> u32 {
    let quality = if quality.is_finite() { quality.clamp(0.1, 1.0) } else { 0.9 };
    let scale = 31.0 - (quality - 0.1) / 0.9 * 29.0;
    scale.round().clamp(2.0, 31.0) as u32
}

/// The command line for pulling exactly one frame out of `input` at `seconds`.
pub fn extract_args(
    input: &str,
    seconds: f64,
    output: &str,
    source: VideoInfo,
    options: ExtractOptions,
) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-nostdin".into(),
        // Seeking before -i is the fast path, and has been frame-accurate
        // since ffmpeg 2.1 (it decodes forward from the prior keyframe).
        "-ss".into(),
        format_seconds(seconds),
        "-i".into(),
        input.into(),
        "-frames:v".into(),
        "1".into(),
        // Tells ffmpeg this is one image, not the first of a numbered sequence.
        "-update".into(),
        "1".into(),
    ];

    if let Some((w, h)) = scaled_size(source, options.max_width) {
        args.push("-vf".into());
        args.push(format!("scale={w}:{h}:flags=lanczos"));
    }

    match options.format {
        ImageFormat::Png => {}
        ImageFormat::Jpeg => {
            args.push("-q:v".into());
            args.push(jpeg_qscale(options.jpeg_quality).to_string());
        }
    }

    args.push("-y".into());
    args.push(output.into());
    args
}

/// A small JPEG used for the timeline filmstrip and the preview grid.
pub fn thumbnail_args(input: &str, seconds: f64, output: &str, max_width: u32) -> Vec<String> {
    vec![
        "-hide_banner".into(),
        "-loglevel".into(),
        "error".into(),
        "-nostdin".into(),
        "-ss".into(),
        format_seconds(seconds),
        "-i".into(),
        input.into(),
        "-frames:v".into(),
        "1".into(),
        "-update".into(),
        "1".into(),
        // -2 keeps the aspect ratio and rounds to an even height for the encoder.
        "-vf".into(),
        format!("scale={max_width}:-2:flags=fast_bilinear"),
        "-q:v".into(),
        "6".into(),
        "-y".into(),
        output.into(),
    ]
}

/// `frame_0001.png`, `frame_0002.png`, … — zero-padded to at least four digits
/// so the files sort correctly in every file manager and chat upload dialog.
pub fn frame_file_name(index: usize, total: usize, format: ImageFormat) -> String {
    let width = total.to_string().len().max(4);
    format!("frame_{:0width$}.{}", index + 1, format.extension(), width = width)
}

/// ffmpeg reads a plain number of seconds; six decimals is well inside one
/// frame at any sane frame rate.
fn format_seconds(seconds: f64) -> String {
    let seconds = if seconds.is_finite() { seconds.max(0.0) } else { 0.0 };
    format!("{seconds:.6}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn landscape() -> VideoInfo {
        VideoInfo { duration: 10.0, width: 1920, height: 1080, frame_rate: 30.0 }
    }

    #[test]
    fn probe_reads_size_and_duration() {
        let json = r#"{
            "streams": [{"width": 1920, "height": 1080, "duration": "12.5"}],
            "format": {"duration": "12.500000"}
        }"#;
        let info = parse_probe(json).unwrap();
        assert_eq!((info.width, info.height), (1920, 1080));
        assert!((info.duration - 12.5).abs() < 1e-9);
    }

    #[test]
    fn a_rotated_phone_clip_reports_portrait_dimensions() {
        let json = r#"{
            "streams": [{
                "width": 1920, "height": 1080,
                "side_data_list": [{"rotation": -90}]
            }],
            "format": {"duration": "5"}
        }"#;
        let info = parse_probe(json).unwrap();
        assert_eq!((info.width, info.height), (1080, 1920));
    }

    #[test]
    fn the_legacy_rotate_tag_is_honoured_too() {
        let json = r#"{
            "streams": [{"width": 1920, "height": 1080, "tags": {"rotate": "90"}}],
            "format": {"duration": "5"}
        }"#;
        assert_eq!(parse_probe(json).unwrap().width, 1080);
    }

    #[test]
    fn a_180_degree_rotation_does_not_swap_the_axes() {
        let json = r#"{
            "streams": [{"width": 1920, "height": 1080, "side_data_list": [{"rotation": 180}]}],
            "format": {"duration": "5"}
        }"#;
        assert_eq!(parse_probe(json).unwrap().width, 1920);
    }

    #[test]
    fn duration_falls_back_to_the_stream_when_the_container_omits_it() {
        let json = r#"{"streams": [{"width": 640, "height": 480, "duration": "3.0"}], "format": {}}"#;
        assert!((parse_probe(json).unwrap().duration - 3.0).abs() < 1e-9);
    }

    #[test]
    fn files_without_a_video_track_are_rejected_with_a_readable_message() {
        let err = parse_probe(r#"{"streams": [], "format": {"duration": "5"}}"#).unwrap_err();
        assert!(err.contains("no video track"), "{err}");
        let err = parse_probe("not json").unwrap_err();
        assert!(err.contains("Couldn't read"), "{err}");
    }

    #[test]
    fn a_missing_duration_is_an_error_rather_than_a_zero_length_clip() {
        let json = r#"{"streams": [{"width": 640, "height": 480}], "format": {}}"#;
        assert!(parse_probe(json).is_err());
    }

    #[test]
    fn scaling_never_upscales() {
        let small = VideoInfo { duration: 1.0, width: 640, height: 360, frame_rate: 30.0 };
        assert_eq!(scaled_size(small, Some(1280)), None);
        assert_eq!(scaled_size(small, Some(640)), None);
        assert_eq!(scaled_size(landscape(), None), None);
    }

    #[test]
    fn scaling_keeps_the_aspect_ratio_on_even_pixels() {
        assert_eq!(scaled_size(landscape(), Some(1280)), Some((1280, 720)));
        let portrait = VideoInfo { duration: 1.0, width: 1080, height: 1920, frame_rate: 30.0 };
        let (w, h) = scaled_size(portrait, Some(640)).unwrap();
        assert_eq!(w, 640);
        assert_eq!(h % 2, 0);
        assert!((h as f64 / w as f64 - 1920.0 / 1080.0).abs() < 0.02);
    }

    #[test]
    fn quality_maps_onto_ffmpegs_inverted_scale() {
        assert_eq!(jpeg_qscale(1.0), 2);
        assert_eq!(jpeg_qscale(0.1), 31);
        assert!(jpeg_qscale(0.9) > 2 && jpeg_qscale(0.9) < 10);
        // Out-of-range and nonsense values still produce a legal qscale.
        for q in [-5.0, 0.0, 2.0, f64::NAN, f64::INFINITY] {
            assert!((2..=31).contains(&jpeg_qscale(q)), "q={q}");
        }
    }

    #[test]
    fn extraction_seeks_before_the_input_and_writes_one_frame() {
        let args = extract_args("/v/clip.mp4", 3.5, "/out/frame_0001.png", landscape(), ExtractOptions::default());
        let ss = args.iter().position(|a| a == "-ss").unwrap();
        let i = args.iter().position(|a| a == "-i").unwrap();
        assert!(ss < i, "-ss must come before -i for the fast seek path");
        assert_eq!(args[ss + 1], "3.500000");
        assert!(args.windows(2).any(|w| w[0] == "-frames:v" && w[1] == "1"));
        assert_eq!(args.last().unwrap(), "/out/frame_0001.png");
        // PNG is lossless — no quality flag should be passed.
        assert!(!args.iter().any(|a| a == "-q:v"));
        assert!(!args.iter().any(|a| a == "-vf"));
    }

    #[test]
    fn jpeg_and_downscaling_add_exactly_the_flags_they_need() {
        let opts = ExtractOptions {
            format: ImageFormat::Jpeg,
            jpeg_quality: 0.9,
            max_width: Some(960),
        };
        let args = extract_args("/v/clip.mp4", 0.0, "/out/f.jpg", landscape(), opts);
        let vf = args.iter().position(|a| a == "-vf").unwrap();
        assert_eq!(args[vf + 1], "scale=960:540:flags=lanczos");
        assert!(args.windows(2).any(|w| w[0] == "-q:v"));
    }

    #[test]
    fn negative_and_nonsense_timestamps_never_reach_ffmpeg() {
        let args = extract_args("/v/c.mp4", -3.0, "/o/f.png", landscape(), ExtractOptions::default());
        assert_eq!(args[args.iter().position(|a| a == "-ss").unwrap() + 1], "0.000000");
        let args = extract_args("/v/c.mp4", f64::NAN, "/o/f.png", landscape(), ExtractOptions::default());
        assert_eq!(args[args.iter().position(|a| a == "-ss").unwrap() + 1], "0.000000");
    }

    #[test]
    fn frame_names_sort_correctly() {
        assert_eq!(frame_file_name(0, 12, ImageFormat::Png), "frame_0001.png");
        assert_eq!(frame_file_name(11, 12, ImageFormat::Jpeg), "frame_0012.jpg");
        // Padding grows past four digits so 10000 frames still sort as text.
        assert_eq!(frame_file_name(0, 12_345, ImageFormat::Png), "frame_00001.png");
    }

    #[test]
    fn the_frame_rate_is_read_and_falls_back_sensibly() {
        let json = r#"{"streams":[{"width":8,"height":8,"avg_frame_rate":"30000/1001"}],"format":{"duration":"5"}}"#;
        assert!((parse_probe(json).unwrap().frame_rate - 29.97).abs() < 0.01);

        // "0/0" means ffprobe doesn't know — fall through to r_frame_rate.
        let json = r#"{"streams":[{"width":8,"height":8,"avg_frame_rate":"0/0","r_frame_rate":"25/1"}],"format":{"duration":"5"}}"#;
        assert_eq!(parse_probe(json).unwrap().frame_rate, 25.0);

        // Neither is present — a safe default rather than a divide by zero.
        let json = r#"{"streams":[{"width":8,"height":8}],"format":{"duration":"5"}}"#;
        assert_eq!(parse_probe(json).unwrap().frame_rate, 30.0);
    }

    #[test]
    fn the_last_decodable_time_lands_on_the_final_frame_not_past_it() {
        // A 2s clip at 10fps has its last frame at 1.9s.
        let info = VideoInfo { duration: 2.0, width: 8, height: 8, frame_rate: 10.0 };
        let t = info.last_decodable_time();
        assert!(t < 1.9, "must not ask for a time past the last frame's start");
        assert!(t > 1.8, "but must still land inside the last frame");

        // Degenerate inputs stay in range instead of going negative.
        for info in [
            VideoInfo { duration: 0.0, width: 8, height: 8, frame_rate: 30.0 },
            VideoInfo { duration: 0.01, width: 8, height: 8, frame_rate: 30.0 },
            VideoInfo { duration: 5.0, width: 8, height: 8, frame_rate: 0.0 },
            VideoInfo { duration: f64::NAN, width: 8, height: 8, frame_rate: 30.0 },
        ] {
            let t = info.last_decodable_time();
            assert!(t >= 0.0 && t.is_finite(), "{info:?} -> {t}");
        }
    }

    #[test]
    fn options_deserialise_from_the_shape_the_ui_sends() {
        // The window sends camelCase JSON; if these names drift, quality and
        // downscaling silently stop working rather than failing loudly.
        let opts: ExtractOptions =
            serde_json::from_str(r#"{"format":"jpeg","jpegQuality":0.8,"maxWidth":960}"#).unwrap();
        assert_eq!(opts.format, ImageFormat::Jpeg);
        assert_eq!(opts.max_width, Some(960));
        assert!((opts.jpeg_quality - 0.8).abs() < 1e-9);

        // "Original" scale arrives as null, and may be omitted entirely.
        let opts: ExtractOptions =
            serde_json::from_str(r#"{"format":"png","jpegQuality":0.9,"maxWidth":null}"#).unwrap();
        assert_eq!(opts.max_width, None);
        let opts: ExtractOptions =
            serde_json::from_str(r#"{"format":"png","jpegQuality":0.9}"#).unwrap();
        assert_eq!(opts.max_width, None);
    }

    #[test]
    fn video_info_round_trips_through_the_window() {
        let info = VideoInfo { duration: 12.5, width: 1920, height: 1080, frame_rate: 25.0 };
        let json = serde_json::to_string(&info).unwrap();
        assert_eq!(serde_json::from_str::<VideoInfo>(&json).unwrap(), info);
    }

    #[test]
    fn probe_asks_only_for_the_first_video_stream() {
        let args = probe_args("/v/clip.mp4");
        assert!(args.windows(2).any(|w| w[0] == "-select_streams" && w[1] == "v:0"));
        assert_eq!(args.last().unwrap(), "/v/clip.mp4");
    }
}
