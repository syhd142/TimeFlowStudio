import Charts
import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ProjectModel

    var body: some View {
        NavigationSplitView {
            FrameSidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        } content: {
            VStack(spacing: 0) {
                PreviewPane()
                Divider()
                LuminanceChart()
                    .frame(height: 280)
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 500, ideal: 720)
        } detail: {
            InspectorPane()
                .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 380)
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Select Images…") {
                        model.chooseImageFiles()
                    }
                    Button("Select Folder…") {
                        model.chooseSequenceFolder()
                    }
                    Divider()
                    Button("Relink Missing Files…") {
                        model.chooseRelinkFolder()
                    }
                    .disabled(model.missingFrameCount == 0)
                } label: {
                    Label("Import", systemImage: "photo.stack")
                }
                .disabled(model.isBusy)
                .help("Import selected images or an entire folder")

                Button {
                    model.analyzeLuminance()
                } label: {
                    Label("Analyze", systemImage: "waveform.path.ecg")
                }
                .disabled(model.project.frames.isEmpty || model.isBusy)
                .help("Analyze luminance for deflicker")

                Button {
                    model.chooseXMPDestination()
                } label: {
                    Label("XMP", systemImage: "doc.badge.arrow.up")
                }
                .disabled(model.project.frames.isEmpty || model.isBusy)
                .help("Export XMP sidecars")

                Button {
                    model.chooseStarTrailDestination()
                } label: {
                    Label("Star Trail", systemImage: "moon.stars")
                }
                .disabled(model.project.frames.isEmpty || model.isBusy)
                .help("Stack all frames into a star trail TIFF")

                Button {
                    model.chooseVideoDestination()
                } label: {
                    Label("Video", systemImage: "film")
                }
                .disabled(model.project.frames.isEmpty || model.isBusy)
                .help("Export a QuickTime movie")
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .alert("TimeFlow Studio", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
    }
}

private struct FrameSidebar: View {
    @EnvironmentObject private var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.project.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(model.project.frames.count) frames")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.missingFrameCount > 0 {
                        Button {
                            model.chooseRelinkFolder()
                        } label: {
                            Label(
                                "\(model.missingFrameCount) missing",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .help("Choose the new folder containing the moved source images")
                    }
                }
                Spacer()
            }
            .padding(12)

            Divider()

            if model.project.frames.isEmpty {
                ContentUnavailableView(
                    "No Sequence",
                    systemImage: "photo.stack",
                    description: Text("Import a folder containing RAW, JPEG, TIFF, HEIC, or PNG images.")
                )
            } else {
                List(selection: Binding(
                    get: { model.selectedIndex },
                    set: { if let value = $0 { model.selectFrame(value) } }
                )) {
                    ForEach(model.project.frames.indices, id: \.self) { index in
                        let frame = model.project.frames[index]
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(frame.displayName)
                                    .lineLimit(1)
                                if let luminance = frame.luminance {
                                    Text("L \(luminance, format: .number.precision(.fractionLength(4)))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.isFrameMissing(at: index) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                    .help("Source file is missing")
                            }
                            if model.project.keyframes.contains(where: { $0.frameIndex == index }) {
                                Image(systemName: "diamond.fill")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                            }
                            if model.project.meteorFrameIndices?.contains(index) == true {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.cyan)
                                    .font(.caption)
                                    .help("Marked meteor frame")
                            }
                        }
                        .tag(index)
                    }
                }
                .disabled(model.isBusy)
            }
        }
    }
}

private struct PreviewPane: View {
    @EnvironmentObject private var model: ProjectModel
    @State private var image: NSImage?
    @State private var isRendering = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
            if let selected = model.selectedIndex, model.isFrameMissing(at: selected) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 46, weight: .thin))
                    Text("Source File Missing")
                        .font(.title3)
                    Button("Relink Missing Files…") {
                        model.chooseRelinkFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
                .foregroundStyle(.white)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            } else if model.selectedFrame != nil {
                ProgressView("Rendering preview…")
                    .controlSize(.large)
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 52, weight: .thin))
                    Text("TimeFlow Studio")
                        .font(.title2)
                    Text("Import a sequence to start a clean, non-destructive timelapse workflow.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.previewRevision) {
            await render()
        }
    }

    private func render() async {
        guard let frame = model.selectedFrame else {
            image = nil
            return
        }
        guard FileManager.default.fileExists(atPath: frame.url.path) else {
            image = nil
            return
        }
        isRendering = true
        let adjustment = model.selectedFinalAdjustment
        do {
            try await Task.sleep(for: .milliseconds(120))
            try Task.checkCancellation()
            let rendered = try await PreviewRenderer.shared.render(
                url: frame.url,
                maxPixelSize: 1_400,
                adjustment: adjustment
            )
            try Task.checkCancellation()
            image = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        } catch is CancellationError {
            // A newer frame or slider value superseded this preview request.
        } catch {
            model.presentedError = error.localizedDescription
        }
        isRendering = false
    }
}

private struct LuminanceChart: View {
    @EnvironmentObject private var model: ProjectModel

    var body: some View {
        let corrections = model.deflickerCorrections
        let luminanceSamples = ChartSampler.downsample(
            model.project.frames.map(\.luminance),
            maxPoints: 400
        )
        let correctionSamples = ChartSampler.downsample(
            corrections.map(Optional.some),
            maxPoints: 400
        )

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Luminance & correction")
                    .font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    chartKey(color: .orange, title: "Measured luminance")
                    chartKey(color: .blue, title: "Exposure correction (EV)", dashed: true)
                    chartKey(color: .purple, title: "Keyframes", dashed: true)
                }
            }

            if let selected = model.selectedIndex,
               model.project.frames.indices.contains(selected) {
                HStack(spacing: 14) {
                    Text("Frame \(selected + 1)")
                        .foregroundStyle(.secondary)
                    if let luminance = model.project.frames[selected].luminance {
                        Text("Measured \(luminance.formatted(.number.precision(.fractionLength(4))))")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Measured —")
                            .foregroundStyle(.secondary)
                    }
                    if corrections.indices.contains(selected) {
                        Text("Correction \(signedEV(corrections[selected]))")
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                }
                .font(.caption.monospacedDigit())
            }

            Chart {
                ForEach(model.project.keyframes) { keyframe in
                    RuleMark(x: .value("Keyframe", keyframe.frameIndex + 1))
                        .foregroundStyle(.purple.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(luminanceSamples) { sample in
                    LineMark(
                        x: .value("Frame", sample.index + 1),
                        y: .value("Luminance", sample.value)
                    )
                    .foregroundStyle(.orange)
                    .interpolationMethod(.catmullRom)
                }
                if let selected = model.selectedIndex {
                    RuleMark(x: .value("Selected", selected + 1))
                        .foregroundStyle(.white.opacity(0.55))
                    if model.project.frames.indices.contains(selected),
                       let luminance = model.project.frames[selected].luminance {
                        PointMark(
                            x: .value("Selected frame", selected + 1),
                            y: .value("Selected luminance", luminance)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(75)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxisLabel("Luminance")
            .frame(maxHeight: .infinity)

            Chart {
                ForEach(model.project.keyframes) { keyframe in
                    RuleMark(x: .value("Keyframe", keyframe.frameIndex + 1))
                        .foregroundStyle(.purple.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(correctionSamples) { sample in
                    LineMark(
                        x: .value("Frame", sample.index + 1),
                        y: .value("Correction", sample.value)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, dash: [5, 3]))
                    .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("Neutral", 0))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                if let selected = model.selectedIndex {
                    RuleMark(x: .value("Selected", selected + 1))
                        .foregroundStyle(.white.opacity(0.55))
                    if corrections.indices.contains(selected) {
                        PointMark(
                            x: .value("Selected frame", selected + 1),
                            y: .value("Selected correction", corrections[selected])
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(75)
                    }
                }
            }
            .chartYAxisLabel("EV")
            .chartLegend(.hidden)
            .frame(maxHeight: .infinity)
        }
    }

    private func chartKey(color: Color, title: String, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 18, height: dashed ? 2 : 3)
                .overlay {
                    if dashed {
                        HStack(spacing: 3) {
                            Color.clear.frame(width: 3)
                            Color(nsColor: .windowBackgroundColor).frame(width: 3)
                            Color.clear.frame(width: 3)
                        }
                    }
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func signedEV(_ value: Double) -> String {
        String(format: "%+.3f EV", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct InspectorPane: View {
    @EnvironmentObject private var model: ProjectModel

    var body: some View {
        Form {
            Section("Frame") {
                if let frame = model.selectedFrame, let index = model.selectedIndex {
                    LabeledContent("Number", value: "\(index + 1) / \(model.project.frames.count)")
                    LabeledContent("File", value: frame.displayName)
                    if model.isFrameMissing(at: index) {
                        LabeledContent("Source file") {
                            Button("Missing — Relink…") {
                                model.chooseRelinkFolder()
                            }
                            .foregroundStyle(.red)
                            .disabled(model.isBusy)
                        }
                    }
                    if let dimensions = dimensions(frame) {
                        LabeledContent("Dimensions", value: dimensions)
                    }
                    if let iso = frame.metadata.iso {
                        LabeledContent("ISO", value: "\(Int(iso))")
                    }
                    if frame.sourceAdjustment != nil {
                        LabeledContent("Source XMP", value: "Loaded safely")
                    }
                    if let luminance = frame.luminance {
                        LabeledContent(
                            "Measured luminance",
                            value: luminance.formatted(.number.precision(.fractionLength(4)))
                        )
                    }
                    let corrections = model.deflickerCorrections
                    if corrections.indices.contains(index) {
                        LabeledContent(
                            "Exposure correction",
                            value: signedEV(corrections[index])
                        )
                    }
                    Button(model.isSelectedFrameMarkedAsMeteor ? "Unmark meteor frame" : "Mark as meteor frame") {
                        model.toggleSelectedFrameMeteor()
                    }
                    .help("Preserve this frame's meteor when transient aircraft and satellite streak removal is enabled")
                } else {
                    Text("No frame selected")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyframe adjustment") {
                HStack {
                    Button {
                        model.goToPreviousKeyframe()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canGoToPreviousKeyframe)
                    .help("Go to previous keyframe")

                    Spacer()
                    Text("\(model.project.keyframes.count) keyframes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        model.goToNextKeyframe()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canGoToNextKeyframe)
                    .help("Go to next keyframe")
                }

                AdjustmentSlider(
                    title: "Exposure",
                    value: $model.draftAdjustment.exposureEV,
                    range: -5...5,
                    suffix: "EV",
                    fractionDigits: 2
                )
                AdjustmentSlider(
                    title: "Temperature",
                    value: $model.draftAdjustment.temperature,
                    range: 2_000...20_000,
                    suffix: "K",
                    fractionDigits: 0
                )
                AdjustmentSlider(
                    title: "Tint",
                    value: $model.draftAdjustment.tint,
                    range: -150...150,
                    fractionDigits: 1
                )
                AdjustmentSlider(
                    title: "Contrast",
                    value: $model.draftAdjustment.contrast,
                    range: -100...100,
                    fractionDigits: 1
                )
                AdjustmentSlider(
                    title: "Saturation",
                    value: $model.draftAdjustment.saturation,
                    range: -100...100,
                    fractionDigits: 1
                )

                HStack {
                    Button(model.hasKeyframeAtSelection ? "Update keyframe" : "Set keyframe") {
                        model.commitKeyframe()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedFrame == nil)

                    Button("Remove") {
                        model.removeKeyframe()
                    }
                    .disabled(!model.hasKeyframeAtSelection)
                }

                ExposureKeyframeCurve()
                    .frame(height: 165)

                HStack {
                    Button("Copy") {
                        model.copySelectedKeyframe()
                    }
                    .disabled(!model.hasKeyframeAtSelection)

                    Button("Paste") {
                        model.pasteKeyframeAtSelection()
                    }
                    .disabled(model.selectedFrame == nil || model.copiedKeyframeAdjustment == nil)
                }

                LabeledContent("Batch exposure") {
                    TextField(
                        "EV",
                        value: $model.keyframeBatchExposureOffset,
                        format: .number.precision(.fractionLength(2))
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 82)
                }
                Button("Apply offset to all keyframes") {
                    model.applyBatchExposureOffset()
                }
                .disabled(model.project.keyframes.isEmpty || model.keyframeBatchExposureOffset == 0)
            }
            .onChange(of: model.draftAdjustment) { _, _ in model.draftChanged() }

            Section("Deflicker") {
                Text("Removes short frame-to-frame brightness jumps while preserving gradual light changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    LabeledContent("Strength", value: model.project.deflickerStrength, format: .percent.precision(.fractionLength(0)))
                    Slider(value: $model.project.deflickerStrength, in: 0...1)
                }
                Stepper("Smoothing window: \(model.project.deflickerWindow)", value: $model.project.deflickerWindow, in: 1...31, step: 2)
                Text(model.project.deflickerWindow == 1 ? "Window 1 disables temporal correction." : "Larger windows reject longer brightness disturbances.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: model.project.deflickerStrength) { _, _ in model.deflickerChanged() }
            .onChange(of: model.project.deflickerWindow) { _, _ in model.deflickerChanged() }

            Section("Video") {
                Picker(
                    "Resolution preset",
                    selection: Binding(
                        get: { model.videoResolutionPreset },
                        set: { model.applyVideoResolutionPreset($0) }
                    )
                ) {
                    ForEach(VideoResolutionPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if model.videoResolutionPreset == .custom {
                    LabeledContent("Width") {
                        videoNumberField(
                            value: $model.project.exportSettings.width,
                            help: "Custom output video width in pixels"
                        )
                    }
                    LabeledContent("Height") {
                        videoNumberField(
                            value: $model.project.exportSettings.height,
                            help: "Custom output video height in pixels"
                        )
                    }
                }

                Picker("Scaling", selection: $model.project.exportSettings.scalingMode) {
                    ForEach(VideoScalingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("FPS") {
                    videoNumberField(
                        value: $model.project.exportSettings.framesPerSecond,
                        help: "Output frames per second"
                    )
                }

                LabeledContent("Meteor frames", value: "\(model.meteorFrameCount) marked")
                Stepper(
                    "Meteor hold: \(model.project.exportSettings.meteorHoldSeconds, format: .number.precision(.fractionLength(1))) s",
                    value: $model.project.exportSettings.meteorHoldSeconds,
                    in: 0...2,
                    step: 0.1
                )
                .disabled(model.meteorFrameCount == 0)
                Text("Applies to ordinary timelapse, star-trail growth and mixed videos. Set to 0 for no hold.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker("Codec", selection: $model.project.exportSettings.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .pickerStyle(.menu)

                if model.project.exportSettings.codec.usesBitRate {
                    Toggle(
                        "Automatic bitrate",
                        isOn: $model.project.exportSettings.automaticBitRate
                    )
                    if model.project.exportSettings.automaticBitRate {
                        LabeledContent(
                            "Bitrate",
                            value: "\(model.videoEffectiveBitRateMbps) Mbps (Auto)"
                        )
                    } else {
                        LabeledContent("Bitrate") {
                            HStack(spacing: 5) {
                                videoNumberField(
                                    value: $model.project.exportSettings.bitRateMbps,
                                    help: "Target video bitrate in megabits per second"
                                )
                                Text("Mbps")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    LabeledContent("Bitrate", value: "Managed by ProRes")
                }

                Picker("Color space", selection: $model.project.exportSettings.colorSpace) {
                    ForEach(VideoColorSpace.allCases) { colorSpace in
                        Text(colorSpace.displayName).tag(colorSpace)
                    }
                }
                .pickerStyle(.menu)

                let videoMaximumFrame = max(model.project.frames.count, 1)
                LabeledContent("Start frame") {
                    frameRangeField(
                        value: $model.project.exportSettings.startFrame,
                        range: 1...videoMaximumFrame,
                        help: "First frame included in the exported video"
                    )
                }
                .onChange(of: model.project.exportSettings.startFrame) { _, _ in
                    model.videoStartChanged()
                }
                LabeledContent("End frame") {
                    frameRangeField(
                        value: $model.project.exportSettings.endFrame,
                        range: 1...videoMaximumFrame,
                        help: "Last frame included in the exported video"
                    )
                }
                .onChange(of: model.project.exportSettings.endFrame) { _, _ in
                    model.videoEndChanged()
                }
                LabeledContent(
                    "Selected",
                    value: "\(max(0, model.project.exportSettings.endFrame - model.project.exportSettings.startFrame + 1)) frames"
                )
                if !model.project.frames.isEmpty, !model.isVideoFrameRangeValid {
                    Text("End frame must be greater than or equal to Start frame.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button("Export video…") {
                    model.chooseVideoDestination()
                }
                .disabled(model.project.frames.isEmpty || model.isBusy || !model.isVideoFrameRangeValid)
            }
            .onChange(of: model.project.exportSettings) { _, _ in
                model.videoSettingsChanged()
            }

            Section("Star trail") {
                Text("Lighten-stacks a selected range. Best for a fixed tripod and consistently framed photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let maximumFrame = max(model.project.frames.count, 1)
                LabeledContent("Start frame") {
                    frameRangeField(
                        value: $model.starTrailStartFrame,
                        range: 1...maximumFrame,
                        help: "First frame included in the star trail"
                    )
                }
                .onChange(of: model.starTrailStartFrame) { _, _ in model.starTrailStartChanged() }
                LabeledContent("End frame") {
                    frameRangeField(
                        value: $model.starTrailEndFrame,
                        range: 1...maximumFrame,
                        help: "Last frame included in the star trail"
                    )
                }
                .onChange(of: model.starTrailEndFrame) { _, _ in model.starTrailEndChanged() }
                LabeledContent(
                    "Selected",
                    value: "\(max(0, model.starTrailEndFrame - model.starTrailStartFrame + 1)) frames"
                )
                if !model.project.frames.isEmpty, !model.isStarTrailFrameRangeValid {
                    Text("End frame must be greater than or equal to Start frame.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Stepper(
                    "Gap filling: \(model.starTrailGapFillingRadius) px",
                    value: $model.starTrailGapFillingRadius,
                    in: 0...3
                )
                Text("A small radius bridges short gaps but also makes trails slightly thicker.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Remove isolated airplane/satellite streaks", isOn: $model.starTrailRemoveTransientStreaks)
                Text("Uses neighboring frames to reject bright marks that appear only once. Marked meteor frames are preserved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Comet tail", isOn: $model.starTrailCometEnabled)
                if model.starTrailCometEnabled {
                    Stepper(
                        "Tail length: \(model.starTrailCometLength) frames",
                        value: $model.starTrailCometLength,
                        in: 10...500,
                        step: 10
                    )
                }

                Button("Export star trail TIFF…") {
                    model.chooseStarTrailDestination()
                }
                .disabled(model.project.frames.isEmpty || model.isBusy || !model.isStarTrailFrameRangeValid)

                Divider()
                Picker("Growth video resolution", selection: $model.starTrailVideoResolution) {
                    ForEach(VideoResolutionPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if model.starTrailVideoResolution == .custom {
                    LabeledContent("Growth width") {
                        videoNumberField(
                            value: $model.starTrailVideoCustomWidth,
                            help: "Custom star-trail video width in pixels"
                        )
                    }
                    LabeledContent("Growth height") {
                        videoNumberField(
                            value: $model.starTrailVideoCustomHeight,
                            help: "Custom star-trail video height in pixels"
                        )
                    }
                }

                Picker("Growth video scaling", selection: $model.starTrailVideoScalingMode) {
                    ForEach(VideoScalingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("Growth video FPS") {
                    videoNumberField(
                        value: $model.starTrailVideoFPS,
                        help: "Frames per second for the growing star trail video"
                    )
                }

                Picker("Growth video codec", selection: $model.starTrailVideoCodec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .pickerStyle(.menu)

                if model.starTrailVideoCodec.usesBitRate {
                    Toggle("Automatic bitrate", isOn: $model.starTrailVideoAutomaticBitRate)
                    if model.starTrailVideoAutomaticBitRate {
                        LabeledContent(
                            "Bitrate",
                            value: "\(model.starTrailVideoEffectiveBitRateMbps) Mbps (Auto)"
                        )
                    } else {
                        LabeledContent("Bitrate") {
                            HStack(spacing: 5) {
                                videoNumberField(
                                    value: $model.starTrailVideoBitRateMbps,
                                    help: "Target bitrate for the star trail growth video"
                                )
                                Text("Mbps")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    LabeledContent("Bitrate", value: "Managed by ProRes")
                }

                Picker("Growth video color space", selection: $model.starTrailVideoColorSpace) {
                    ForEach(VideoColorSpace.allCases) { colorSpace in
                        Text(colorSpace.displayName).tag(colorSpace)
                    }
                }
                .pickerStyle(.menu)

                Text("4K H.264 is the compatibility default. Source size may require a high-performance player.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("Export growth video…") {
                    model.chooseStarTrailVideoDestination()
                }
                .disabled(model.project.frames.isEmpty || model.isBusy || !model.isStarTrailFrameRangeValid)

                Divider()
                Text("Timelapse → Star Trail")
                    .font(.headline)
                Text("Combines the Video range with the Star trail range above. Set Video End and Star trail Start to the same frame; that shared frame becomes the seamless transition.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledContent("Output", value: model.hybridVideoOutputDescription)
                Text("Uses the Video resolution, FPS, codec, bitrate and color space for the entire mixed video. Growth video settings only affect standalone star-trail growth exports.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Transition: \(model.hybridTransitionFrames) frames",
                    value: $model.hybridTransitionFrames,
                    in: 0...max(model.project.exportSettings.framesPerSecond * 5, 1)
                )
                Text("Blends normal motion into the accumulated trail. Set to 0 for an immediate switch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Stepper(
                    "Final hold: \(model.hybridFinalHoldSeconds) seconds",
                    value: $model.hybridFinalHoldSeconds,
                    in: 0...10
                )

                if !model.project.frames.isEmpty, !model.isHybridFrameRangeValid {
                    Text("Video End frame must match Star trail Start frame.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button("Export timelapse → star trail…") {
                    model.chooseHybridVideoDestination()
                }
                .disabled(model.project.frames.isEmpty || model.isBusy || !model.isHybridFrameRangeValid)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.starTrailSettingsSnapshot) { _, _ in
            model.starTrailSettingsChanged()
        }
        // Disabling the complete AppKit-backed Form makes macOS rebuild the
        // focus chain for every slider and text field. On macOS 26 that can
        // enter an AttributeGraph/focus-navigation cycle after an import.
        .allowsHitTesting(!model.isBusy)
        .opacity(model.isBusy ? 0.82 : 1)
    }

    private func dimensions(_ frame: FrameRecord) -> String? {
        guard let width = frame.metadata.pixelWidth, let height = frame.metadata.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    private func videoNumberField(value: Binding<Int>, help: String) -> some View {
        TextField("", value: value, format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 100)
            .help(help)
    }

    private func frameRangeField(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            TextField("", value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
        .help(help)
    }

    private func signedEV(_ value: Double) -> String {
        String(format: "%+.3f EV", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct ExposureKeyframeCurve: View {
    @EnvironmentObject private var model: ProjectModel
    @State private var draggingKeyframeID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Exposure curve")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("drag points")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.project.keyframes.isEmpty {
                ContentUnavailableView(
                    "No Keyframes",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("Set a keyframe to edit its curve.")
                )
            } else {
                Chart {
                    ForEach(curveSamples) { sample in
                        LineMark(
                            x: .value("Frame", sample.index + 1),
                            y: .value("Exposure", sample.value)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }
                    ForEach(model.project.keyframes) { keyframe in
                        PointMark(
                            x: .value("Frame", keyframe.frameIndex + 1),
                            y: .value("Exposure", keyframe.adjustment.exposureEV)
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(70)
                    }
                    RuleMark(y: .value("Neutral", 0))
                        .foregroundStyle(.secondary.opacity(0.35))
                }
                .chartYScale(domain: -5...5)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: [-5, 0, 5])
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if draggingKeyframeID == nil {
                                            model.beginKeyframeCurveEdit()
                                        }
                                        drag(value, proxy: proxy, geometry: geometry)
                                    }
                                    .onEnded { _ in
                                        draggingKeyframeID = nil
                                        model.endKeyframeCurveEdit()
                                    }
                            )
                    }
                }
            }
        }
    }

    private var curveSamples: [ChartSample] {
        let frameCount = model.project.frames.count
        guard frameCount > 0 else { return [] }
        let sampleCount = min(frameCount, 200)
        if sampleCount == 1 {
            return [ChartSample(
                index: 0,
                value: AdjustmentEngine.adjustment(at: 0, keyframes: model.project.keyframes).exposureEV
            )]
        }
        return (0..<sampleCount).map { position in
            let index = position * (frameCount - 1) / (sampleCount - 1)
            return ChartSample(
                index: index,
                value: AdjustmentEngine.adjustment(at: index, keyframes: model.project.keyframes).exposureEV
            )
        }
    }

    private func drag(_ value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let frame = geometry[plotFrame]
        let x = value.location.x - frame.origin.x
        let y = value.location.y - frame.origin.y
        guard let frameValue = proxy.value(atX: x, as: Double.self),
              let exposure = proxy.value(atY: y, as: Double.self) else { return }

        if draggingKeyframeID == nil {
            draggingKeyframeID = model.project.keyframes.min {
                abs(Double($0.frameIndex + 1) - frameValue) < abs(Double($1.frameIndex + 1) - frameValue)
            }?.id
        }
        guard let draggingKeyframeID else { return }
        model.updateKeyframeExposure(id: draggingKeyframeID, exposureEV: exposure)
    }
}

private struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""
    var fractionDigits = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(parameterLabel) {
                TextField(
                    "",
                    value: clampedValue,
                    format: .number.precision(.fractionLength(fractionDigits))
                )
                .accessibilityLabel(parameterLabel)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .help("Enter a value from \(range.lowerBound.formatted()) to \(range.upperBound.formatted())")
            }
            Slider(value: clampedValue, in: range)
        }
    }

    private var parameterLabel: String {
        suffix.isEmpty ? title : "\(title) (\(suffix))"
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        )
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: ProjectModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView(value: model.progress)
                    .frame(width: 140)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if model.lastExportedVideoURL != nil {
                Button("Show in Finder") {
                    model.revealLastExportedVideo()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .help("Reveal the exported video in Finder")
            }
            Spacer()
            if model.canCancelCurrentOperation {
                Button("Cancel") {
                    model.cancelCurrentOperation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Cancel the current operation safely")
            }
            if !model.project.keyframes.isEmpty {
                Text("\(model.project.keyframes.count) keyframes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }
}
