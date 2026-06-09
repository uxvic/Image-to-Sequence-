import SwiftUI

/// Centralised dark palette + spacing, echoing the reference editor look
/// (near-black canvas, slightly lighter panels, green primary accent).
enum Theme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let panelElevated = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let stroke = Color.white.opacity(0.08)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)

    static let accent = Color(red: 0.18, green: 0.80, blue: 0.44)
    static let warning = Color(red: 0.95, green: 0.65, blue: 0.20)

    static let cornerRadius: CGFloat = 10
}

/// Formats a number of seconds as `M:SS.cc` (minutes, seconds, centiseconds).
func formatTimecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
    let totalCentis = Int((seconds * 100).rounded())
    let minutes = totalCentis / 6000
    let secs = (totalCentis / 100) % 60
    let centis = totalCentis % 100
    return String(format: "%d:%02d.%02d", minutes, secs, centis)
}
