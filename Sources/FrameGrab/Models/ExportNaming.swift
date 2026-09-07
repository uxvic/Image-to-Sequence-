import Foundation

/// Turns whatever the user typed into the export **Name** field into something
/// the file system will actually accept, and keeps a folder export from
/// colliding with what is already sitting on disk.
enum ExportNaming {

    /// Longest name we'll produce, in UTF-8 bytes. APFS/HFS+ cap a single path
    /// component at 255 bytes; staying well under that leaves room for `.zip`,
    /// a " 2" disambiguating suffix and the temporary staging prefix.
    static let maxBytes = 180

    /// `/` and `:` are the two characters macOS genuinely can't store in a file
    /// name (the Finder silently swaps one for the other), and control
    /// characters produce names nothing can reopen. The rest are stripped so a
    /// name typed here survives a trip through Windows, Linux or a zip tool.
    private static let illegal = CharacterSet(charactersIn: #"/:\?%*|"<>"#)
        .union(.controlCharacters)

    /// Trimmed, stripped of illegal characters, and never empty — falls back to
    /// `fallback` (and finally to "frames") when the user clears the field.
    static func sanitize(_ raw: String, fallback: String) -> String {
        clean(raw) ?? clean(fallback) ?? "frames"
    }

    private static func clean(_ raw: String) -> String? {
        // Replace rather than delete, so "a/b" reads as "a b" instead of "ab".
        let replaced = String(raw.unicodeScalars.map { illegal.contains($0) ? Character(" ") : Character($0) })
        let collapsed = replaced.split(separator: " ").joined(separator: " ")
        let trimmed = trimEnds(collapsed)
        guard !trimmed.isEmpty else { return nil }
        // A leading dot would hide the file, and truncation can expose a new
        // trailing space, so trim once more after clipping to the byte budget.
        let clipped = trimEnds(truncate(trimmed))
        return clipped.isEmpty ? nil : clipped
    }

    /// Leading dots hide the file in Finder; trailing dots and spaces confuse
    /// other operating systems once the export is shared.
    private static func trimEnds(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func truncate(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var result = name
        // Drop whole characters so a multi-byte scalar is never cut in half.
        while result.utf8.count > maxBytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    /// `directory/name`, or `directory/name 2`, `name 3`… when that is taken.
    ///
    /// Returning a path that doesn't exist yet is what makes folder exports
    /// safe: the app never merges its frames into someone else's folder, and
    /// the cleanup after a cancelled export can only ever delete a folder this
    /// export created.
    static func uniqueFolderURL(in directory: URL, name: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
            // Absurd, but an unbounded loop here would hang the main thread.
            if suffix > 999 {
                return directory.appendingPathComponent("\(name) \(UUID().uuidString)", isDirectory: true)
            }
        }
        return candidate
    }
}
