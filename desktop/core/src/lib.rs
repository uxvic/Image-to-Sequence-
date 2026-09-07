//! The parts of FrameGrab that have nothing to do with any one operating
//! system: which timestamps to sample, what to call the export, and how to ask
//! ffmpeg for a frame.
//!
//! Keeping them here — free of Tauri, WebKit and platform file dialogs — is
//! what makes them testable on any machine, and what keeps the macOS and
//! Windows builds behaving identically.

pub mod ffmpeg;
pub mod frames;
pub mod naming;

pub use ffmpeg::{ExtractOptions, ImageFormat, VideoInfo};
pub use frames::{FrameSelection, SelectionMode};
pub use naming::sanitize;
