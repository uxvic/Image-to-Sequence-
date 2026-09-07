//! Finding the ffmpeg and ffprobe binaries the app drives.
//!
//! Three places are tried, in the order that respects the user most: an
//! explicit override, the copies a release build ships beside the executable,
//! and finally whatever is on `PATH`.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Where ffmpeg came from, so the UI can say something useful when it is
/// missing rather than just failing on the first export.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolStatus {
    pub available: bool,
    pub ffmpeg_path: Option<String>,
    pub ffprobe_path: Option<String>,
    pub version: Option<String>,
}

pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
}

impl Tools {
    pub fn locate() -> Option<Self> {
        Some(Self {
            ffmpeg: find("ffmpeg")?,
            ffprobe: find("ffprobe")?,
        })
    }

    pub fn status() -> ToolStatus {
        match Self::locate() {
            Some(tools) => ToolStatus {
                available: true,
                ffmpeg_path: Some(tools.ffmpeg.display().to_string()),
                ffprobe_path: Some(tools.ffprobe.display().to_string()),
                version: tools.version(),
            },
            None => ToolStatus {
                available: false,
                ffmpeg_path: find("ffmpeg").map(|p| p.display().to_string()),
                ffprobe_path: find("ffprobe").map(|p| p.display().to_string()),
                version: None,
            },
        }
    }

    fn version(&self) -> Option<String> {
        let output = command(&self.ffmpeg).arg("-version").output().ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        text.lines().next().map(str::to_string)
    }
}

/// A `Command` that doesn't flash a console window on Windows — the app runs
/// ffmpeg once per frame, so without this an export would strobe.
pub fn command(program: &Path) -> Command {
    // Only the Windows branch below mutates it.
    #[allow(unused_mut)]
    let mut command = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

fn find(name: &str) -> Option<PathBuf> {
    let file_name = executable_name(name);

    // 1. An explicit override, for a copy kept somewhere unusual.
    if let Ok(dir) = std::env::var("FRAMEGRAB_FFMPEG_DIR") {
        let candidate = Path::new(&dir).join(&file_name);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }

    // 2. Beside the app's own executable — where a release build puts them.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for candidate in [
                dir.join(&file_name),
                // macOS app bundles keep helpers in Contents/Resources.
                dir.join("../Resources").join(&file_name),
            ] {
                if is_executable(&candidate) {
                    return Some(candidate);
                }
            }
        }
    }

    // 3. On PATH — the common case for a developer or a Homebrew install.
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(&file_name))
        .find(|candidate| is_executable(candidate))
}

fn executable_name(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

fn is_executable(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return std::fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    }
    #[cfg(not(unix))]
    {
        true
    }
}
