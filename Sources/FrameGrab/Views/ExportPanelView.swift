import SwiftUI

/// Right-hand settings panel: how many frames, what format/scale, and the
/// export action with progress.
struct ExportPanelView: View {
    @EnvironmentObject var model: EditorModel

    private let presets = [8, 12, 16, 24]

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
                HStack {
                    Text("Rate").foregroundColor(Theme.textSecondary)
                    Spacer()
                    Text("\(model.settings.fps, specifier: "%.1f") fps")
                        .foregroundColor(Theme.textPrimary)
                        .monospacedDigit()
                }
                Slider(value: $model.settings.fps, in: 0.5...30, step: 0.5)
                    .tint(Theme.accent)

            case .count:
                Stepper(value: $model.settings.frameCount, in: 1...300) {
                    HStack {
                        Text("Count").foregroundColor(Theme.textSecondary)
                        Spacer()
                        Text("\(model.settings.frameCount) frames")
                            .foregroundColor(Theme.textPrimary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { value in
                        Button("\(value)") { model.settings.frameCount = value }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(model.settings.frameCount == value ? Theme.accent : nil)
                    }
                }
            }

            estimateLabel
        }
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

            Text(model.settings.outputMode == .zip
                 ? "Frames are bundled into a single .zip."
                 : "Frames are written as loose files into a folder.")
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
        }
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
                Button(action: { model.export() }) {
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
