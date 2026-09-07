//! Which timestamps inside the selected region get sampled.
//!
//! A direct port of the macOS app's `FrameExporter.frameTimes`, so the two
//! builds hand an LLM the same frames for the same clip and settings.

use serde::{Deserialize, Serialize};

/// Bounds for the frame **Count**, whether it is typed, stepped or picked from
/// a preset. The upper bound doubles as the hard cap, so a mistyped `999999`
/// can't queue an export that never finishes.
pub const COUNT_MIN: u32 = 1;
pub const COUNT_MAX: u32 = 2000;

/// Bounds for the capture **Rate**, in frames per second. The typed field and
/// the slider share this range so the two can never disagree.
pub const FPS_MIN: f64 = 0.5;
pub const FPS_MAX: f64 = 30.0;

/// Ceiling on an FPS-mode sample list, in case a very long clip meets a very
/// high rate. Matches the macOS app.
const FPS_SAFETY_CAP: usize = 10_000;

/// How the frames inside the selected region are chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SelectionMode {
    /// Extract frames at a fixed rate (frames per second).
    Fps,
    /// Extract an exact number of evenly-spaced frames.
    Count,
}

/// The frame-picking half of the export settings.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct FrameSelection {
    pub mode: SelectionMode,
    pub fps: f64,
    pub count: u32,
}

impl Default for FrameSelection {
    fn default() -> Self {
        Self { mode: SelectionMode::Count, fps: 2.0, count: 12 }
    }
}

impl FrameSelection {
    /// Values forced back inside their allowed ranges. Applied before every
    /// use: the count and rate can both be typed, so neither is trusted.
    pub fn clamped(self) -> Self {
        Self {
            mode: self.mode,
            fps: if self.fps.is_finite() { self.fps.clamp(FPS_MIN, FPS_MAX) } else { FPS_MIN },
            count: self.count.clamp(COUNT_MIN, COUNT_MAX),
        }
    }
}

/// The exact timestamps (in seconds) that will be sampled for the given region.
///
/// Used for the export itself, for the live "≈ N images" estimate and for the
/// preview grid, so those three can never disagree about what will be written.
pub fn frame_times(start: f64, end: f64, selection: FrameSelection) -> Vec<f64> {
    if !start.is_finite() || !end.is_finite() {
        return Vec::new();
    }
    let selection = selection.clamped();
    let lo = start.min(end).max(0.0);
    let hi = start.max(end).max(0.0);
    let span = (hi - lo).max(0.0);

    match selection.mode {
        SelectionMode::Fps => {
            let step = 1.0 / selection.fps;
            let mut times = Vec::new();
            let mut t = lo;
            while t <= hi + 1e-6 {
                times.push(t.min(hi));
                t += step;
                if times.len() >= FPS_SAFETY_CAP {
                    break;
                }
            }
            if times.is_empty() {
                times.push(lo);
            }
            times
        }
        SelectionMode::Count => {
            let n = selection.count;
            if n == 1 {
                return vec![lo + span / 2.0];
            }
            (0..n).map(|i| lo + span * f64::from(i) / f64::from(n - 1)).collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count_sel(count: u32) -> FrameSelection {
        FrameSelection { mode: SelectionMode::Count, fps: 2.0, count }
    }

    fn fps_sel(fps: f64) -> FrameSelection {
        FrameSelection { mode: SelectionMode::Fps, fps, count: 12 }
    }

    #[test]
    fn count_spans_the_region_end_to_end() {
        let times = frame_times(2.0, 6.0, count_sel(5));
        assert_eq!(times, vec![2.0, 3.0, 4.0, 5.0, 6.0]);
    }

    #[test]
    fn a_single_frame_lands_in_the_middle() {
        assert_eq!(frame_times(0.0, 10.0, count_sel(1)), vec![5.0]);
    }

    #[test]
    fn count_is_capped_rather_than_trusted() {
        assert_eq!(frame_times(0.0, 10.0, count_sel(999_999)).len(), COUNT_MAX as usize);
        assert_eq!(frame_times(0.0, 10.0, count_sel(0)).len(), COUNT_MIN as usize);
    }

    #[test]
    fn fps_steps_by_the_rate_and_never_passes_the_end() {
        let times = frame_times(0.0, 2.0, fps_sel(2.0));
        assert_eq!(times, vec![0.0, 0.5, 1.0, 1.5, 2.0]);
        assert!(times.iter().all(|t| *t <= 2.0));
    }

    #[test]
    fn fps_is_capped_so_a_long_clip_cannot_run_away() {
        // 10 hours at 30fps would be over a million samples.
        let times = frame_times(0.0, 36_000.0, fps_sel(30.0));
        assert_eq!(times.len(), 10_000);
    }

    #[test]
    fn a_reversed_selection_is_read_the_right_way_round() {
        assert_eq!(frame_times(6.0, 2.0, count_sel(5)), frame_times(2.0, 6.0, count_sel(5)));
    }

    #[test]
    fn an_empty_region_still_yields_frames_at_that_instant() {
        assert_eq!(frame_times(3.0, 3.0, count_sel(4)), vec![3.0, 3.0, 3.0, 3.0]);
        assert_eq!(frame_times(3.0, 3.0, fps_sel(2.0)), vec![3.0]);
    }

    #[test]
    fn nonsense_input_produces_no_frames_instead_of_panicking() {
        assert!(frame_times(f64::NAN, 5.0, count_sel(4)).is_empty());
        assert!(frame_times(0.0, f64::INFINITY, count_sel(4)).is_empty());
    }

    #[test]
    fn a_nonsense_rate_falls_back_to_the_slowest_allowed() {
        let sel = fps_sel(f64::NAN).clamped();
        assert_eq!(sel.fps, FPS_MIN);
        assert!(!frame_times(0.0, 4.0, fps_sel(f64::NAN)).is_empty());
    }
}
