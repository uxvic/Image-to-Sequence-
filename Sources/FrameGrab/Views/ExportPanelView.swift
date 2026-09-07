import SwiftUI
import Foundation

/// Right-hand settings panel: how many frames, what format/scale, what the
/// export is called, and the export action with progress.
struct ExportPanelView: View {
    @EnvironmentObject var model: EditorModel

    private let presets = [8, 12, 16, 24]

    /// Typed numbers live here until they're committed on Return or on losing
    /// focus. Binding a text field straight to the settings would push a
    /// half-typed number ("1" on the way to "12") through the model, rebuilding
    /// the preview and throwing away hand-picked frame exclusions mid-keystroke.
    @State private var countText = ""
    @State private var fpsText = ""
    @FocusState private var focusedField: Field?
    /// `@FocusState` only reports where focus *went*, so remember where it was
    /// to know which field needs committing.
    @State private var previousField: Field?

    private enum Field: Hashable {
        case count, fps, name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Export")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)

                frameSelectionSection
                formatSection
                outputSection
                Spacer(minLength: 0)
                exportSection
            }
            .padding(20)
        }
        .disabled(model.isLoading)
        .onAppear { syncTypedFields() }
        // Clicking away from a field commits it, matching how the rest of macOS
        // treats an inspector panel.
        .onChange(of: focusedField) { field in
            if previousField == .count { commitCount() }
            if previousField == .fps { commitFPS() }
            previousField = field
        }
        // Presets, the stepper and the slider all write to the model directly —
        // mirror those back into the text so the two never drift apart.
        .onChange(of: model.settings.frameCount) { value in
            countText = String(value)
        }
        .onChange(of: model.settings.fps) { value in
            fpsText = Self.formatFPS(value)
        }
    }

    // MARK: Frame selection

    private var frameSelectionSection: some View {
        PanelSection(title: "Frames") {
            Picker("", selection: $model.settings.mode) {
                ForEach(SelectionMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.settings.mode {
            case .fps:
                HStack(spacing: 8) {
                    Text("Rate").foregroundColor(Theme.textSecondary)
                    Spacer()
                    numberField(text: $fpsText, field: .fps, width: 60, onCommit: commitFPS)
                    Text("fps").foregroundColor(Theme.textSecondary)
                }
                Slider(value: $model.settings.fps, in: ExportSettings.fpsRange, step: 0.5)
                    .tint(Theme.accent)

            case .count:
                HStack(spacing: 8) {
                    Text("Count").foregroundColor(Theme.textSecondary)
                    Spacer()
                    numberField(text: $countText, field: .count, width: 60, onCommit: commitCount)
                    Stepper("", value: $model.settings.frameCount, in: ExportSettings.frameCountRange)
                        .labelsHidden()
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { value in
                        Button("\(value)") { model.settings.frameCount = value }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.settings.frameCount == value ? Theme.accent : nil)
                    }
                }
                Text("Type any number from \(ExportSettings.frameCountRange.lowerBound) to \(ExportSettings.frameCountRange.upperBound).")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }

            estimateLabel
        }
    }

    /// A small right-aligned numeric field that commits on Return.
    private func numberField(
        text: Binding<String>,
        field: Field,
        width: CGFloat,
        onCommit: @escaping () -> Void
    ) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: width)
            .focused($focusedField, equals: field)
            .onSubmit(onCommit)
    }

    private var estimateLabel: some View {
        let planned = model.plannedFrameCount
        let included = model.includedFrameCount
        let excluded = planned - included

        return VStack(alignment: .leading, spacing: 6) {
            Text("\(included) image\(included == 1 ? "" : "s")")
                .font(.callout.weight(.medium))
                .foregroundColor(Theme.accent)

            if excluded > 0 {
                Text("\(excluded) excluded in preview")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
            }

            if included > 20 {
                Text("Most LLMs accept ~20 images per message — consider fewer.")
                    .font(.caption)
                    .foregroundColor(Theme.warning)
            }

            Button {
                model.togglePreview()
            } label: {
                HStack {
                    Image(systemName: model.isPreviewVisible ? "eye.slash" : "square.grid.3x3")
                    Text(model.isPreviewVisible ? "Hide preview" : "Preview frames")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .disabled(model.videoURL == nil || planned == 0)
            .help("See the exact frames that will be exported, and click any of them to leave it out")
        }
    }

    // MARK: Format

    private var formatSection: some View {
        PanelSection(title: "Format") {
            Picker("", selection: $model.settings.format) {
                ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.settings.format == .jpeg {
                HStack {
                    Text("Quality").foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(model.settings.jpegQuality * 100))%")
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                }
                Slider(value: $model.settings.jpegQuality, in: 0.1...1)
                    .tint(Theme.accent)
            }

            HStack {
                Text("Scale").foregroundColor(Theme.textSecondary)
                Spacer()
                Picker("", selection: $model.settings.scale) {
                    ForEach(ScaleOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }

    // MARK: Output

    private var outputSection: some View {
        PanelSection(title: "Output") {
            Picker("", selection: $model.settings.outputMode) {
                ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Text("Name").foregroundColor(Theme.textSecondary)
                TextField(model.defaultExportName, text: $model.exportName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .help("Name for the exported .zip or folder — leave blank to use the video's name")
            }

            Text(outputDescription)
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows the name the export will really end up with, after the typed text
    /// has been trimmed and stripped of characters the file system rejects.
    private var outputDescription: String {
        let name = model.resolvedExportName
        return model.settings.outputMode == .zip
            ? "Saves one archive: \(name).zip"
            : "Creates a folder: \(name)"
    }

    // MARK: Export action

    private var exportLabel: String {
        let n = model.includedFrameCount
        guard n > 0 else { return "Nothing to export" }
        let noun = n == 1 ? "Image" : "Images"
        return model.settings.outputMode == .zip
            ? "Export \(n) \(noun) as ZIP…"
            : "Export \(n) \(noun)…"
    }

    private var exportSection: some View {
        VStack(spacing: 12) {
            if model.isExporting {
                ProgressView(value: model.exportProgress)
                    .tint(Theme.accent)
                HStack {
                    Text("\(Int(model.exportProgress * 100))%")
                        .foregroundColor(Theme.textSecondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { model.cancelExport() }
                        .controlSize(.small)
                }
            } else {
                Button(action: startExport) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text(exportLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
                .disabled(model.videoURL == nil || model.includedFrameCount == 0)
            }
        }
    }

    // MARK: Typed value handling

    /// Clicking Export while a number is still being typed should use it, not
    /// the last committed value — a button click doesn't take focus off a text
    /// field on macOS, so nothing else would commit it.
    private func startExport() {
        commitCount()
        commitFPS()
        focusedField = nil
        // The model recomputes the planned frames from `settings` one main-queue
        // turn later, so give it that turn before it reads them back.
        let editor = model
        DispatchQueue.main.async { editor.export() }
    }

    private func syncTypedFields() {
        countText = String(model.settings.frameCount)
        fpsText = Self.formatFPS(model.settings.fps)
    }

    private func commitCount() {
        let digits = countText.filter { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else {
            // Nothing usable was typed — put the current value back.
            countText = String(model.settings.frameCount)
            return
        }
        let range = ExportSettings.frameCountRange
        // More digits than an Int can hold clearly means "as many as possible".
        let typed = Int(digits) ?? range.upperBound
        let clamped = min(max(typed, range.lowerBound), range.upperBound)
        model.settings.frameCount = clamped
        countText = String(clamped)
    }

    private func commitFPS() {
        // Accept the comma decimal separator too — it's what a lot of keyboards
        // produce, and rejecting it just looks broken.
        let normalized = fpsText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let typed = Double(normalized), typed.isFinite else {
            fpsText = Self.formatFPS(model.settings.fps)
            return
        }
        let range = ExportSettings.fpsRange
        let clamped = min(max(typed, range.lowerBound), range.upperBound)
        // One decimal place: finer than the slider's step, still readable.
        let rounded = (clamped * 10).rounded() / 10
        model.settings.fps = rounded
        fpsText = Self.formatFPS(rounded)
    }

    private static func formatFPS(_ value: Double) -> String {
        // "2" rather than "2.0", but "2.5" keeps its decimal.
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}

/// A titled group of controls with consistent spacing.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
            content
        }
    }
}
