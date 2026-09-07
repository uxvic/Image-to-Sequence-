//! Turning whatever the user typed into the export **Name** field into
//! something every file system involved will accept.
//!
//! "Every file system" is the point: a name typed on a Mac routinely ends up
//! inside a `.zip` that is unpacked on Windows, so the rules here are the
//! union of both platforms' rules rather than the host's alone.

use std::path::{Path, PathBuf};

/// Longest name produced, in UTF-8 bytes. APFS/HFS+ cap a single path
/// component at 255 bytes and NTFS at 255 UTF-16 units; staying well under
/// both leaves room for `.zip`, a " 2" disambiguating suffix and a temporary
/// staging prefix.
pub const MAX_NAME_BYTES: usize = 180;

/// `/` and `:` are the two characters macOS genuinely can't store; the rest
/// are the ones Windows rejects. Control characters produce names nothing can
/// reopen anywhere.
const ILLEGAL: &[char] = &['/', ':', '\\', '?', '%', '*', '|', '"', '<', '>'];

/// Windows refuses these as a file's stem, whatever the extension, and has
/// since DOS. Unpacking a `CON.zip` there simply fails.
const RESERVED_STEMS: &[&str] = &[
    "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
    "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
];

/// Trimmed, stripped of illegal characters and never empty — falls back to
/// `fallback` (and finally to `"frames"`) when the user clears the field.
pub fn sanitize(raw: &str, fallback: &str) -> String {
    clean(raw)
        .or_else(|| clean(fallback))
        .unwrap_or_else(|| "frames".to_string())
}

fn clean(raw: &str) -> Option<String> {
    // Replace rather than delete, so "a/b" reads as "a b" instead of "ab".
    let replaced: String = raw
        .chars()
        .map(|c| if ILLEGAL.contains(&c) || c.is_control() { ' ' } else { c })
        .collect();
    // Collapses the runs of spaces the replacement leaves behind.
    let collapsed = replaced.split_whitespace().collect::<Vec<_>>().join(" ");

    let trimmed = trim_ends(&collapsed);
    if trimmed.is_empty() {
        return None;
    }
    // Truncating can expose a new trailing space, so trim once more after
    // clipping to the byte budget.
    let clipped = trim_ends(&truncate_bytes(&trimmed, MAX_NAME_BYTES));
    if clipped.is_empty() {
        return None;
    }
    Some(escape_reserved(clipped))
}

/// A leading dot hides the file on macOS and Linux; a trailing dot or space is
/// silently dropped by Windows, which turns "report ." into a name that no
/// longer matches what the app reported.
fn trim_ends(name: &str) -> String {
    name.trim_matches(|c| c == '.' || c == ' ').to_string()
}

fn truncate_bytes(name: &str, max_bytes: usize) -> String {
    if name.len() <= max_bytes {
        return name.to_string();
    }
    let mut end = max_bytes;
    // Never cut a multi-byte character in half.
    while end > 0 && !name.is_char_boundary(end) {
        end -= 1;
    }
    name[..end].to_string()
}

fn escape_reserved(name: String) -> String {
    let stem = name.split('.').next().unwrap_or_default().to_ascii_lowercase();
    if RESERVED_STEMS.contains(&stem.as_str()) {
        format!("{name}_")
    } else {
        name
    }
}

/// `parent/name`, or `parent/name 2`, `name 3`… when that is taken.
///
/// Returning a path that doesn't exist yet is what makes folder exports safe:
/// frames are never mixed into someone else's folder, and cleaning up after a
/// cancelled export can only ever delete a folder that export created.
pub fn unique_folder(parent: &Path, name: &str) -> PathBuf {
    let mut candidate = parent.join(name);
    let mut suffix = 2u32;
    while candidate.exists() {
        candidate = parent.join(format!("{name} {suffix}"));
        suffix += 1;
        // Absurd, but an unbounded loop here would hang the export.
        if suffix > 999 {
            return parent.join(format!("{name} {}", unique_tag()));
        }
    }
    candidate
}

/// The default name for a clip: `<video>_frames`.
pub fn default_name_for(video_path: &Path) -> String {
    let stem = video_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    if stem.is_empty() {
        "frames".to_string()
    } else {
        format!("{stem}_frames")
    }
}

fn unique_tag() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos().to_string())
        .unwrap_or_else(|_| "copy".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ordinary_name_is_left_alone() {
        assert_eq!(sanitize("UI demo reel", "clip_frames"), "UI demo reel");
    }

    #[test]
    fn path_separators_become_spaces_rather_than_vanishing() {
        assert_eq!(sanitize("my/clip:2", "clip_frames"), "my clip 2");
        assert_eq!(sanitize(r"a\b", "clip_frames"), "a b");
    }

    #[test]
    fn blank_and_unusable_input_falls_back() {
        assert_eq!(sanitize("", "clip_frames"), "clip_frames");
        assert_eq!(sanitize("    ", "clip_frames"), "clip_frames");
        assert_eq!(sanitize("...", "clip_frames"), "clip_frames");
        assert_eq!(sanitize("///", "clip_frames"), "clip_frames");
        // Both unusable — there is still always a name.
        assert_eq!(sanitize("", "//:"), "frames");
    }

    #[test]
    fn hidden_and_trailing_forms_are_trimmed() {
        assert_eq!(sanitize("...hidden", "x"), "hidden");
        assert_eq!(sanitize("trailing.  ", "x"), "trailing");
    }

    #[test]
    fn control_characters_never_survive() {
        let out = sanitize("line\nbreak\ttab\u{0}", "x");
        assert_eq!(out, "line break tab");
        assert!(!out.chars().any(char::is_control));
    }

    #[test]
    fn long_names_are_clipped_to_the_byte_budget() {
        let out = sanitize(&"a".repeat(500), "x");
        assert_eq!(out.len(), MAX_NAME_BYTES);
    }

    #[test]
    fn multibyte_names_are_clipped_without_being_cut_in_half() {
        let out = sanitize(&"😀".repeat(200), "x");
        assert!(out.len() <= MAX_NAME_BYTES);
        // Still valid UTF-8 made only of whole emoji.
        assert!(out.chars().all(|c| c == '😀'));
    }

    #[test]
    fn windows_device_names_are_escaped() {
        assert_eq!(sanitize("CON", "x"), "CON_");
        assert_eq!(sanitize("nul", "x"), "nul_");
        assert_eq!(sanitize("com4.old", "x"), "com4.old_");
        // Only the exact stems — a name that merely starts with one is fine.
        assert_eq!(sanitize("console", "x"), "console");
    }

    #[test]
    fn the_result_is_always_usable() {
        for raw in ["", " ", ".", "..", "/", "CON", "\u{0}", "😀", &"z".repeat(400)] {
            let out = sanitize(raw, "fallback");
            assert!(!out.is_empty());
            assert!(!out.starts_with('.'));
            assert!(!out.ends_with('.') && !out.ends_with(' '));
            assert!(out.len() <= MAX_NAME_BYTES + 1); // +1 for a reserved-name underscore
            assert!(!out.chars().any(|c| ILLEGAL.contains(&c) || c.is_control()));
        }
    }

    #[test]
    fn the_default_name_follows_the_video() {
        assert_eq!(default_name_for(Path::new("/a/b/clip.mp4")), "clip_frames");
        assert_eq!(default_name_for(Path::new("/a/b/.mp4")), ".mp4_frames");
        assert_eq!(default_name_for(Path::new("/")), "frames");
    }

    #[test]
    fn a_taken_folder_name_gets_a_suffix_instead_of_being_reused() {
        let base = std::env::temp_dir().join(format!("framegrab-test-{}", unique_tag()));
        std::fs::create_dir_all(base.join("shots")).unwrap();

        assert_eq!(unique_folder(&base, "other"), base.join("other"));
        assert_eq!(unique_folder(&base, "shots"), base.join("shots 2"));

        std::fs::create_dir_all(base.join("shots 2")).unwrap();
        assert_eq!(unique_folder(&base, "shots"), base.join("shots 3"));

        std::fs::remove_dir_all(&base).unwrap();
    }
}
