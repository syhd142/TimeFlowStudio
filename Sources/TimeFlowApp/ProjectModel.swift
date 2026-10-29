import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectModel: ObservableObject {
    @Published var project = TimeFlowProject()
    @Published var selectedIndex: Int?
    @Published var draftAdjustment = Adjustment.neutral
    @Published var isBusy = false
    @Published var progress = 0.0
    @Published var statusMessage = "Import an image sequence to begin."
    @Published var presentedError: String?
    @Published private(set) var lastExportedVideoURL: URL?
    @Published var previewRevision = 0
    @Published private(set) var deflickerCorrections: [Double] = []
    @Published var starTrailStartFrame = 1
    @Published var starTrailEndFrame = 1
    @Published var starTrailGapFillingRadius = 0
    @Published var starTrailRemoveTransientStreaks = false
    @Published var starTrailCometEnabled = false
    @Published var starTrailCometLength = 80
    @Published var starTrailVideoFPS = 25
    @Published var starTrailVideoResolution = VideoResolutionPreset.ultraHD
    @Published var starTrailVideoCodec = VideoCodec.h264
    @Published var starTrailVideoAutomaticBitRate = true
    @Published var starTrailVideoBitRateMbps = 45
    @Published var starTrailVideoColorSpace = VideoColorSpace.rec709
    @Published var starTrailVideoScalingMode = VideoScalingMode.fill
    @Published var starTrailVideoCustomWidth = 1_920
    @Published var starTrailVideoCustomHeight = 1_080
    @Published var videoResolutionPreset = VideoResolutionPreset.fullHD
    @Published var hybridTransitionFrames = 12
    @Published var hybridFinalHoldSeconds = 3
    @Published var keyframeBatchExposureOffset = 0.0
    @Published private(set) var copiedKeyframeAdjustment: Adjustment?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var canCancelCurrentOperation = false
    @Published private(set) var missingFrameCount = 0

    private var projectURL: URL?
    private let autosaveEnabled: Bool
    private var autosaveTask: Task<Void, Never>?
    private var undoStack: [ProjectSnapshot] = []
    private var redoStack: [ProjectSnapshot] = []
    private var curveEditIsActive = false
    private var currentOperationTask: Task<Void, Never>?
    private var currentOperationDescription = "operation"
    private var analyzedFrameCount = 0
    private var analysisLastCheckpoint = Date.distantPast
    private var hasRememberedStarTrailSettings = false
    private static let recentStarTrailSettingsKey = "recentStarTrailWorkflowSettings.v1"

    private struct ProjectSnapshot {
        var project: TimeFlowProject
        var selectedIndex: Int?
    }

    init(autosaveEnabled: Bool = true) {
        self.autosaveEnabled = autosaveEnabled
        if autosaveEnabled, let remembered = Self.loadRecentStarTrailSettings() {
            applyStarTrailSettings(remembered)
            hasRememberedStarTrailSettings = true
        }
    }

    var starTrailSettingsSnapshot: StarTrailWorkflowSettings {
        StarTrailWorkflowSettings(
            startFrame: starTrailStartFrame,
            endFrame: starTrailEndFrame,
            gapFillingRadius: starTrailGapFillingRadius,
            removeTransientStreaks: starTrailRemoveTransientStreaks,
            cometEnabled: starTrailCometEnabled,
            cometLength: starTrailCometLength,
            growthVideoFPS: starTrailVideoFPS,
            growthVideoResolution: starTrailVideoResolution,
            growthVideoCodec: starTrailVideoCodec,
            growthVideoAutomaticBitRate: starTrailVideoAutomaticBitRate,
            growthVideoBitRateMbps: starTrailVideoBitRateMbps,
            growthVideoColorSpace: starTrailVideoColorSpace,
            growthVideoScalingMode: starTrailVideoScalingMode,
            growthVideoCustomWidth: starTrailVideoCustomWidth,
            growthVideoCustomHeight: starTrailVideoCustomHeight,
            hybridTransitionFrames: hybridTransitionFrames,
            hybridFinalHoldSeconds: hybridFinalHoldSeconds
        )
    }

    var selectedFrame: FrameRecord? {
        guard let selectedIndex, project.frames.indices.contains(selectedIndex) else { return nil }
        return project.frames[selectedIndex]
    }

    func isFrameMissing(at index: Int) -> Bool {
        guard project.frames.indices.contains(index) else { return false }
        return !FileManager.default.fileExists(atPath: project.frames[index].url.path)
    }

    var selectedFinalAdjustment: Adjustment {
        guard let selectedIndex else { return draftAdjustment }
        var value = draftAdjustment
        let corrections = deflickerCorrections
        if corrections.indices.contains(selectedIndex) {
            value.exposureEV += corrections[selectedIndex]
        }
        return value
    }

    var hasKeyframeAtSelection: Bool {
        guard let selectedIndex else { return false }
        return project.keyframes.contains { $0.frameIndex == selectedIndex }
    }

    var isSelectedFrameMarkedAsMeteor: Bool {
        guard let selectedIndex else { return false }
        return project.meteorFrameIndices?.contains(selectedIndex) == true
    }

    var meteorFrameCount: Int {
        project.meteorFrameIndices?.count ?? 0
    }

    func toggleSelectedFrameMeteor() {
        guard let selectedIndex else { return }
        recordUndoSnapshot()
        var marked = Set(project.meteorFrameIndices ?? [])
        if marked.remove(selectedIndex) == nil {
            marked.insert(selectedIndex)
            statusMessage = "Frame \(selectedIndex + 1) marked as a meteor frame."
        } else {
            statusMessage = "Meteor mark removed from frame \(selectedIndex + 1)."
        }
        project.meteorFrameIndices = marked.sorted()
        scheduleAutosave()
    }

    var canGoToPreviousKeyframe: Bool {
        guard let selectedIndex else { return false }
        return project.keyframes.contains { $0.frameIndex < selectedIndex }
    }

    var canGoToNextKeyframe: Bool {
        guard let selectedIndex else { return false }
        return project.keyframes.contains { $0.frameIndex > selectedIndex }
    }

    func chooseSequenceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose an image sequence folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        importSequence(from: directory)
    }

    func chooseImageFiles() {
        let panel = NSOpenPanel()
        panel.title = "Select Images"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        importImages(from: panel.urls)
    }

    func chooseRelinkFolder() {
        guard missingFrameCount > 0 else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the folder containing the moved source images"
        panel.prompt = "Relink"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        relinkSourceFiles(to: directory)
    }

    func relinkSourceFiles(to directory: URL, automatic: Bool = false) {
        guard missingFrameCount > 0, !isBusy else { return }
        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        currentOperationDescription = "source-file relinking"
        statusMessage = automatic
            ? "Searching the moved source folder…"
            : "Relinking missing source files…"
        let snapshot = project
        let worker = Task.detached(priority: .userInitiated) {
            try FileRelinker.relink(project: snapshot, to: directory)
        }
        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if result.relinkedCount > 0 {
                    recordUndoSnapshot()
                    project = result.project
                    recalculateDeflickerCorrections()
                    syncDraftToSelection()
                    scheduleAutosave()
                }
                missingFrameCount = result.remainingMissingCount
                if result.remainingMissingCount == 0 {
                    statusMessage = "Relinked \(result.relinkedCount) source files."
                } else {
                    let ambiguity = result.ambiguousCount > 0
                        ? " \(result.ambiguousCount) filenames were ambiguous."
                        : ""
                    statusMessage = "Relinked \(result.relinkedCount); \(result.remainingMissingCount) still missing.\(ambiguity)"
                }
            } catch is CancellationError {
                statusMessage = "Source-file relinking cancelled."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Source-file relinking failed."
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func importImages(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isBusy = true
        progress = 0
        statusMessage = "Reading selected images…"
        let parentDirectories = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        let commonDirectory = parentDirectories.count == 1 ? parentDirectories.first : nil
        let projectName = commonDirectory?.lastPathComponent ?? "Selected Photos"

        Task {
            do {
                let frames = try await Task.detached(priority: .userInitiated) {
                    try ImageSequenceLoader.load(from: urls)
                }.value
                project = TimeFlowProject(
                    name: projectName,
                    sourceDirectory: commonDirectory,
                    frames: frames
                )
                videoResolutionPreset = .fullHD
                prepareStarTrailSettingsForNewSequence()
                resetVideoRange()
                missingFrameCount = 0
                recalculateDeflickerCorrections()
                selectedIndex = 0
                syncDraftToSelection()
                statusMessage = "Loaded \(frames.count) selected frames. Run luminance analysis next."
                scheduleAutosave()
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Import failed."
            }
            isBusy = false
        }
    }

    func importSequence(from directory: URL) {
        isBusy = true
        progress = 0
        statusMessage = "Reading image sequence…"
        Task {
            do {
                let frames = try await Task.detached(priority: .userInitiated) {
                    try ImageSequenceLoader.load(from: directory)
                }.value
                project = TimeFlowProject(
                    name: directory.lastPathComponent,
                    sourceDirectory: directory,
                    frames: frames
                )
                videoResolutionPreset = .fullHD
                prepareStarTrailSettingsForNewSequence()
                resetVideoRange()
                missingFrameCount = 0
                recalculateDeflickerCorrections()
                selectedIndex = frames.isEmpty ? nil : 0
                syncDraftToSelection()
                statusMessage = "Loaded \(frames.count) frames. Run luminance analysis next."
                scheduleAutosave()
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Import failed."
            }
            isBusy = false
        }
    }

    func analyzeLuminance() {
        guard !project.frames.isEmpty else { return }
        currentOperationTask?.cancel()
        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        statusMessage = "Analyzing luminance…"
        currentOperationDescription = "analysis"
        let urls = project.frames.map(\.url)
        analyzedFrameCount = 0
        analysisLastCheckpoint = Date.distantPast

        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let concurrency = min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 1), 4)
                _ = try await LuminanceAnalyzer.analyze(
                    urls: urls,
                    maxConcurrent: concurrency,
                    batchSize: max(8, min(32, urls.count / 100))
                ) { [weak self] batch, completed, total in
                    await self?.applyLuminanceBatch(batch, completed: completed, total: total)
                }
                recalculateDeflickerCorrections()
                previewRevision += 1
                statusMessage = "Luminance analysis complete. Deflicker corrections are active."
                scheduleAutosave()
            } catch is CancellationError {
                recalculateDeflickerCorrections()
                previewRevision += 1
                statusMessage = "Analysis cancelled. Kept \(analyzedFrameCount) completed measurements."
                scheduleAutosave()
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Analysis stopped after \(analyzedFrameCount) frames. Completed results were kept."
                scheduleAutosave()
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func cancelCurrentOperation() {
        guard canCancelCurrentOperation else { return }
        statusMessage = "Cancelling \(currentOperationDescription)…"
        canCancelCurrentOperation = false
        currentOperationTask?.cancel()
    }

    func selectFrame(_ index: Int) {
        guard project.frames.indices.contains(index) else { return }
        selectedIndex = index
        syncDraftToSelection()
    }

    func syncDraftToSelection() {
        guard let selectedIndex else {
            draftAdjustment = .neutral
            return
        }
        if project.keyframes.isEmpty,
           let sourceAdjustment = project.frames[selectedIndex].sourceAdjustment {
            draftAdjustment = sourceAdjustment
        } else {
            draftAdjustment = AdjustmentEngine.adjustment(at: selectedIndex, keyframes: project.keyframes)
        }
        previewRevision += 1
    }

    func commitKeyframe() {
        guard let selectedIndex else { return }
        recordUndoSnapshot()
        if let index = project.keyframes.firstIndex(where: { $0.frameIndex == selectedIndex }) {
            project.keyframes[index].adjustment = draftAdjustment
        } else {
            project.keyframes.append(AdjustmentKeyframe(frameIndex: selectedIndex, adjustment: draftAdjustment))
        }
        project.keyframes.sort { $0.frameIndex < $1.frameIndex }
        statusMessage = "Keyframe saved at frame \(selectedIndex + 1)."
        previewRevision += 1
        scheduleAutosave()
    }

    func removeKeyframe() {
        guard let selectedIndex else { return }
        recordUndoSnapshot()
        project.keyframes.removeAll { $0.frameIndex == selectedIndex }
        syncDraftToSelection()
        statusMessage = "Keyframe removed from frame \(selectedIndex + 1)."
        scheduleAutosave()
    }

    func beginKeyframeCurveEdit() {
        guard !curveEditIsActive else { return }
        recordUndoSnapshot()
        curveEditIsActive = true
    }

    func endKeyframeCurveEdit() {
        guard curveEditIsActive else { return }
        curveEditIsActive = false
        scheduleAutosave()
    }

    func updateKeyframeExposure(id: UUID, exposureEV: Double) {
        guard let keyframeIndex = project.keyframes.firstIndex(where: { $0.id == id }) else { return }
        project.keyframes[keyframeIndex].adjustment.exposureEV = min(max(exposureEV, -5), 5)
        if selectedIndex == project.keyframes[keyframeIndex].frameIndex {
            draftAdjustment = project.keyframes[keyframeIndex].adjustment
        }
        previewRevision += 1
    }

    func copySelectedKeyframe() {
        guard let selectedIndex,
              let keyframe = project.keyframes.first(where: { $0.frameIndex == selectedIndex }) else { return }
        copiedKeyframeAdjustment = keyframe.adjustment
        statusMessage = "Copied keyframe at frame \(selectedIndex + 1)."
    }

    func pasteKeyframeAtSelection() {
        guard let selectedIndex, let copiedKeyframeAdjustment else { return }
        recordUndoSnapshot()
        if let index = project.keyframes.firstIndex(where: { $0.frameIndex == selectedIndex }) {
            project.keyframes[index].adjustment = copiedKeyframeAdjustment
        } else {
            project.keyframes.append(
                AdjustmentKeyframe(frameIndex: selectedIndex, adjustment: copiedKeyframeAdjustment)
            )
            project.keyframes.sort { $0.frameIndex < $1.frameIndex }
        }
        draftAdjustment = copiedKeyframeAdjustment
        previewRevision += 1
        statusMessage = "Pasted keyframe at frame \(selectedIndex + 1)."
        scheduleAutosave()
    }

    func applyBatchExposureOffset() {
        guard !project.keyframes.isEmpty, keyframeBatchExposureOffset != 0 else { return }
        recordUndoSnapshot()
        for index in project.keyframes.indices {
            project.keyframes[index].adjustment.exposureEV = min(
                max(project.keyframes[index].adjustment.exposureEV + keyframeBatchExposureOffset, -5),
                5
            )
        }
        syncDraftToSelection()
        statusMessage = "Applied \(signedEV(keyframeBatchExposureOffset)) to all keyframes."
        keyframeBatchExposureOffset = 0
        scheduleAutosave()
    }

    func goToPreviousKeyframe() {
        guard let selectedIndex,
              let destination = project.keyframes
                .map(\.frameIndex)
                .filter({ $0 < selectedIndex })
                .max() else { return }
        selectFrame(destination)
        statusMessage = "Selected previous keyframe at frame \(destination + 1)."
    }

    func goToNextKeyframe() {
        guard let selectedIndex,
              let destination = project.keyframes
                .map(\.frameIndex)
                .filter({ $0 > selectedIndex })
                .min() else { return }
        selectFrame(destination)
        statusMessage = "Selected next keyframe at frame \(destination + 1)."
    }

    func draftChanged() {
        previewRevision += 1
    }

    func deflickerChanged() {
        recalculateDeflickerCorrections()
        previewRevision += 1
        scheduleAutosave()
    }

    func chooseProjectDestination() {
        guard !project.frames.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Save TimeFlow Project"
        panel.nameFieldStringValue = "\(project.name).timeflow"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveProject(to: url)
    }

    func saveProject(to url: URL? = nil) {
        persistStarTrailSettings(scheduleProjectAutosave: false)
        let destination = url ?? projectURL
        guard let destination else {
            chooseProjectDestination()
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(project).write(to: destination, options: .atomic)
            projectURL = destination
            statusMessage = "Project saved: \(destination.lastPathComponent)"
            scheduleAutosave()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func chooseProjectToOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open TimeFlow Project"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(from: url)
    }

    func openProject(from url: URL) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode(TimeFlowProject.self, from: Data(contentsOf: url))
            guard loaded.formatVersion <= TimeFlowProject.currentFormatVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            project = loaded
            syncVideoResolutionPresetFromProject()
            restoreStarTrailSettings(loaded.starTrailSettings)
            normalizeVideoRange()
            recalculateDeflickerCorrections()
            missingFrameCount = FileRelinker.missingFrameCount(in: loaded)
            projectURL = url
            selectedIndex = loaded.frames.isEmpty ? nil : 0
            syncDraftToSelection()
            if missingFrameCount > 0 {
                statusMessage = "Project opened with \(missingFrameCount) missing source files."
            } else {
                statusMessage = "Project opened: \(url.lastPathComponent)"
            }
            undoStack.removeAll()
            redoStack.removeAll()
            updateUndoState()
            scheduleAutosave()
            attemptAutomaticRelink(near: url)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func chooseXMPDestination() {
        guard !project.frames.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for XMP sidecars"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        isBusy = true
        statusMessage = "Writing XMP sidecars…"
        let snapshot = project
        let corrections = deflickerCorrections
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try XMPWriter.export(project: snapshot, corrections: corrections, to: directory)
                }.value
                statusMessage = "Exported \(snapshot.frames.count) XMP sidecars."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "XMP export failed."
            }
            isBusy = false
        }
    }

    func chooseVideoDestination() {
        guard !project.frames.isEmpty else { return }
        guard isVideoFrameRangeValid else {
            presentedError = "End frame must be greater than or equal to Start frame."
            statusMessage = "Choose a valid video frame range."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Timelapse Video"
        panel.nameFieldStringValue = "\(project.name).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        lastExportedVideoURL = nil
        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        statusMessage = "Rendering video…"
        currentOperationDescription = "video export"
        let snapshot = project
        let corrections = deflickerCorrections
        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await VideoExporter.export(
                    project: snapshot,
                    corrections: corrections,
                    destination: destination
                ) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                statusMessage = "Video exported: \(destination.lastPathComponent)"
                lastExportedVideoURL = destination
            } catch is CancellationError {
                statusMessage = "Video export cancelled. Partial output was removed."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Video export failed."
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func chooseStarTrailDestination() {
        guard !project.frames.isEmpty else { return }
        guard isStarTrailFrameRangeValid else {
            presentedError = "End frame must be greater than or equal to Start frame."
            statusMessage = "Choose a valid star-trail frame range."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Star Trail Stack"
        panel.nameFieldStringValue = "\(project.name)-star-trail.tiff"
        panel.allowedContentTypes = [.tiff]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        statusMessage = "Stacking star trail frames…"
        currentOperationDescription = "star-trail image export"
        let snapshot = project
        let corrections = deflickerCorrections
        let options = starTrailOptions
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try StarTrailExporter.export(
                project: snapshot,
                corrections: corrections,
                options: options,
                destination: destination
            ) { value in
                Task { @MainActor in self?.progress = value }
            }
        }
        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                statusMessage = "Star trail exported: \(destination.lastPathComponent)"
            } catch is CancellationError {
                statusMessage = "Star trail export cancelled. Existing output was preserved."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Star trail export failed."
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func chooseStarTrailVideoDestination() {
        guard !project.frames.isEmpty else { return }
        guard isStarTrailFrameRangeValid else {
            presentedError = "End frame must be greater than or equal to Start frame."
            statusMessage = "Choose a valid star-trail frame range."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Star Trail Growth Video"
        panel.nameFieldStringValue = "\(project.name)-star-trail-growth.mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        lastExportedVideoURL = nil
        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        statusMessage = "Rendering star trail growth video…"
        currentOperationDescription = "star-trail growth video export"
        let snapshot = project
        let corrections = deflickerCorrections
        let options = starTrailOptions
        let settings = StarTrailVideoSettings(
            resolutionPreset: starTrailVideoResolution,
            framesPerSecond: starTrailVideoFPS,
            codec: starTrailVideoCodec,
            automaticBitRate: starTrailVideoAutomaticBitRate,
            bitRateMbps: starTrailVideoBitRateMbps,
            colorSpace: starTrailVideoColorSpace,
            scalingMode: starTrailVideoScalingMode,
            customWidth: starTrailVideoCustomWidth,
            customHeight: starTrailVideoCustomHeight
        )
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try StarTrailVideoExporter.export(
                project: snapshot,
                corrections: corrections,
                options: options,
                settings: settings,
                destination: destination
            ) { value in
                Task { @MainActor in self?.progress = value }
            }
        }
        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                statusMessage = "Star trail growth video exported: \(destination.lastPathComponent)"
                lastExportedVideoURL = destination
            } catch is CancellationError {
                statusMessage = "Star trail growth video export cancelled. Existing output was preserved."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Star trail growth video export failed."
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func chooseHybridVideoDestination() {
        guard !project.frames.isEmpty else { return }
        guard isHybridFrameRangeValid else {
            presentedError = "Video End frame must match Star trail Start frame for a seamless transition."
            statusMessage = "Make the two hybrid-video ranges meet at the same frame."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Timelapse to Star Trail Video"
        panel.nameFieldStringValue = "\(project.name)-timelapse-to-star-trail.mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        lastExportedVideoURL = nil
        isBusy = true
        canCancelCurrentOperation = true
        progress = 0
        statusMessage = "Rendering timelapse to star-trail video…"
        currentOperationDescription = "hybrid video export"
        let snapshot = project
        let corrections = deflickerCorrections
        let settings = HybridVideoSettings(
            transitionFrames: hybridTransitionFrames,
            finalHoldSeconds: hybridFinalHoldSeconds
        )
        let options = starTrailOptions
        currentOperationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await HybridVideoExporter.export(
                    project: snapshot,
                    corrections: corrections,
                    settings: settings,
                    starTrailOptions: options,
                    destination: destination
                ) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                statusMessage = "Hybrid video exported: \(destination.lastPathComponent)"
                lastExportedVideoURL = destination
            } catch is CancellationError {
                statusMessage = "Hybrid video export cancelled. Partial output was removed."
            } catch {
                presentedError = error.localizedDescription
                statusMessage = "Hybrid video export failed."
            }
            isBusy = false
            canCancelCurrentOperation = false
            currentOperationTask = nil
        }
    }

    func starTrailStartChanged() {
        starTrailStartFrame = min(max(starTrailStartFrame, 1), max(project.frames.count, 1))
    }

    func starTrailEndChanged() {
        starTrailEndFrame = min(max(starTrailEndFrame, 1), max(project.frames.count, 1))
    }

    var isStarTrailFrameRangeValid: Bool {
        !project.frames.isEmpty
            && starTrailStartFrame >= 1
            && starTrailEndFrame <= project.frames.count
            && starTrailStartFrame <= starTrailEndFrame
    }

    var isHybridFrameRangeValid: Bool {
        isVideoFrameRangeValid
            && isStarTrailFrameRangeValid
            && project.exportSettings.endFrame == starTrailStartFrame
    }

    var hybridVideoOutputDescription: String {
        let settings = project.exportSettings
        let width = max(2, settings.width / 2 * 2)
        let height = max(2, settings.height / 2 * 2)
        var components = [
            "\(width) × \(height)",
            settings.scalingMode.displayName,
            settings.codec.displayName,
            "\(max(1, settings.framesPerSecond)) FPS"
        ]
        if settings.codec.usesBitRate {
            let mode = settings.automaticBitRate ? " Auto" : ""
            components.append("\(settings.resolvedBitRateMbps(width: width, height: height)) Mbps\(mode)")
        }
        return components.joined(separator: " · ")
    }

    var videoEffectiveBitRateMbps: Int {
        let settings = project.exportSettings
        let width = max(2, settings.width / 2 * 2)
        let height = max(2, settings.height / 2 * 2)
        return settings.resolvedBitRateMbps(width: width, height: height)
    }

    func revealLastExportedVideo() {
        guard let lastExportedVideoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportedVideoURL])
    }

    var starTrailVideoEffectiveBitRateMbps: Int {
        let sourceWidth = project.frames.first?.metadata.pixelWidth ?? 3_840
        let sourceHeight = project.frames.first?.metadata.pixelHeight ?? 2_160
        let settings = StarTrailVideoSettings(
            resolutionPreset: starTrailVideoResolution,
            framesPerSecond: starTrailVideoFPS,
            codec: starTrailVideoCodec,
            automaticBitRate: starTrailVideoAutomaticBitRate,
            bitRateMbps: starTrailVideoBitRateMbps,
            colorSpace: starTrailVideoColorSpace,
            scalingMode: starTrailVideoScalingMode,
            customWidth: starTrailVideoCustomWidth,
            customHeight: starTrailVideoCustomHeight
        )
        let dimensions = settings.outputDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
        return settings.resolvedBitRateMbps(width: dimensions.width, height: dimensions.height)
    }

    var detectedVideoResolutionPreset: VideoResolutionPreset {
        if let metadata = project.frames.first?.metadata,
           let sourceWidth = metadata.pixelWidth,
           let sourceHeight = metadata.pixelHeight,
           sourceWidth == project.exportSettings.width,
           sourceHeight == project.exportSettings.height {
            return .source
        }
        return VideoResolutionPreset.allCases.first {
            guard let dimensions = $0.dimensions else { return false }
            return dimensions.width == project.exportSettings.width
                && dimensions.height == project.exportSettings.height
        } ?? .custom
    }

    func applyVideoResolutionPreset(_ preset: VideoResolutionPreset) {
        videoResolutionPreset = preset
        if preset == .source,
           let metadata = project.frames.first?.metadata,
           let width = metadata.pixelWidth,
           let height = metadata.pixelHeight {
            project.exportSettings.width = width
            project.exportSettings.height = height
        } else if let dimensions = preset.dimensions {
            project.exportSettings.width = dimensions.width
            project.exportSettings.height = dimensions.height
        }
        videoSettingsChanged()
    }

    func videoStartChanged() {
        let maximum = max(project.frames.count, 1)
        project.exportSettings.startFrame = min(
            max(project.exportSettings.startFrame, 1),
            maximum
        )
        videoSettingsChanged()
    }

    func videoEndChanged() {
        let maximum = max(project.frames.count, 1)
        project.exportSettings.endFrame = min(
            max(project.exportSettings.endFrame, 1),
            maximum
        )
        videoSettingsChanged()
    }

    var isVideoFrameRangeValid: Bool {
        !project.frames.isEmpty
            && project.exportSettings.startFrame >= 1
            && project.exportSettings.endFrame <= project.frames.count
            && project.exportSettings.startFrame <= project.exportSettings.endFrame
    }

    func videoSettingsChanged() {
        scheduleAutosave()
    }

    func starTrailSettingsChanged() {
        persistStarTrailSettings(scheduleProjectAutosave: true)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(ProjectSnapshot(project: project, selectedIndex: selectedIndex))
        restore(previous)
        statusMessage = "Undid the last project change."
        updateUndoState()
        scheduleAutosave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(ProjectSnapshot(project: project, selectedIndex: selectedIndex))
        restore(next)
        statusMessage = "Redid the project change."
        updateUndoState()
        scheduleAutosave()
    }

    func restoreRecoveryIfAvailable() {
        guard project.frames.isEmpty,
              let recovered = try? ProjectRecoveryStore.load(),
              !recovered.frames.isEmpty else { return }
        project = recovered
        syncVideoResolutionPresetFromProject()
        selectedIndex = 0
        restoreStarTrailSettings(recovered.starTrailSettings)
        normalizeVideoRange()
        recalculateDeflickerCorrections()
        missingFrameCount = FileRelinker.missingFrameCount(in: recovered)
        syncDraftToSelection()
        if missingFrameCount > 0 {
            statusMessage = "Recovered \(recovered.name) with \(missingFrameCount) missing source files."
        } else {
            statusMessage = "Recovered autosaved project: \(recovered.name)"
        }
    }

    private var starTrailOptions: StarTrailOptions {
        StarTrailOptions(
            startIndex: max(0, starTrailStartFrame - 1),
            endIndex: max(0, starTrailEndFrame - 1),
            gapFillingRadius: starTrailGapFillingRadius,
            removeTransientStreaks: starTrailRemoveTransientStreaks,
            cometTailLength: starTrailCometEnabled ? starTrailCometLength : nil,
            preservedTransientFrameIndices: Set(project.meteorFrameIndices ?? []),
            meteorHoldSeconds: project.exportSettings.meteorHoldSeconds
        )
    }

    private func resetStarTrailRange() {
        starTrailStartFrame = 1
        starTrailEndFrame = max(project.frames.count, 1)
    }

    private func normalizeStarTrailRange() {
        let maximum = max(project.frames.count, 1)
        starTrailStartFrame = min(max(starTrailStartFrame, 1), maximum)
        starTrailEndFrame = min(max(starTrailEndFrame, 1), maximum)
        if starTrailEndFrame < starTrailStartFrame {
            starTrailEndFrame = starTrailStartFrame
        }
    }

    private func prepareStarTrailSettingsForNewSequence() {
        if hasRememberedStarTrailSettings {
            normalizeStarTrailRange()
        } else {
            resetStarTrailRange()
        }
        persistStarTrailSettings(scheduleProjectAutosave: false)
    }

    private func restoreStarTrailSettings(_ saved: StarTrailWorkflowSettings?) {
        if let saved {
            applyStarTrailSettings(saved)
            hasRememberedStarTrailSettings = true
        } else if !hasRememberedStarTrailSettings {
            resetStarTrailRange()
        }
        normalizeStarTrailRange()
        persistStarTrailSettings(scheduleProjectAutosave: false)
    }

    private func applyStarTrailSettings(_ settings: StarTrailWorkflowSettings) {
        starTrailStartFrame = settings.startFrame
        starTrailEndFrame = settings.endFrame
        starTrailGapFillingRadius = settings.gapFillingRadius
        starTrailRemoveTransientStreaks = settings.removeTransientStreaks
        starTrailCometEnabled = settings.cometEnabled
        starTrailCometLength = settings.cometLength
        starTrailVideoFPS = settings.growthVideoFPS
        starTrailVideoResolution = settings.growthVideoResolution
        starTrailVideoCodec = settings.growthVideoCodec
        starTrailVideoAutomaticBitRate = settings.growthVideoAutomaticBitRate
        starTrailVideoBitRateMbps = settings.growthVideoBitRateMbps
        starTrailVideoColorSpace = settings.growthVideoColorSpace
        starTrailVideoScalingMode = settings.growthVideoScalingMode
        starTrailVideoCustomWidth = settings.growthVideoCustomWidth
        starTrailVideoCustomHeight = settings.growthVideoCustomHeight
        hybridTransitionFrames = settings.hybridTransitionFrames
        hybridFinalHoldSeconds = settings.hybridFinalHoldSeconds
    }

    private func persistStarTrailSettings(scheduleProjectAutosave: Bool) {
        let settings = starTrailSettingsSnapshot
        project.starTrailSettings = settings
        hasRememberedStarTrailSettings = true
        if autosaveEnabled, let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.recentStarTrailSettingsKey)
        }
        if scheduleProjectAutosave {
            scheduleAutosave()
        }
    }

    private static func loadRecentStarTrailSettings() -> StarTrailWorkflowSettings? {
        guard let data = UserDefaults.standard.data(forKey: recentStarTrailSettingsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(StarTrailWorkflowSettings.self, from: data)
    }

    private func resetVideoRange() {
        project.exportSettings.startFrame = 1
        project.exportSettings.endFrame = max(project.frames.count, 1)
    }

    private func normalizeVideoRange() {
        let maximum = max(project.frames.count, 1)
        project.exportSettings.startFrame = min(
            max(project.exportSettings.startFrame, 1),
            maximum
        )
        project.exportSettings.endFrame = min(
            max(project.exportSettings.endFrame, project.exportSettings.startFrame),
            maximum
        )
        if project.exportSettings.startFrame > project.exportSettings.endFrame {
            project.exportSettings.startFrame = project.exportSettings.endFrame
        }
    }

    private func recordUndoSnapshot() {
        undoStack.append(ProjectSnapshot(project: project, selectedIndex: selectedIndex))
        if undoStack.count > 50 {
            undoStack.removeFirst(undoStack.count - 50)
        }
        redoStack.removeAll()
        updateUndoState()
    }

    private func restore(_ snapshot: ProjectSnapshot) {
        project = snapshot.project
        syncVideoResolutionPresetFromProject()
        if let settings = project.starTrailSettings {
            applyStarTrailSettings(settings)
            normalizeStarTrailRange()
        }
        missingFrameCount = FileRelinker.missingFrameCount(in: project)
        if let index = snapshot.selectedIndex, project.frames.indices.contains(index) {
            selectedIndex = index
        } else {
            selectedIndex = project.frames.isEmpty ? nil : 0
        }
        recalculateDeflickerCorrections()
        syncDraftToSelection()
    }

    private func syncVideoResolutionPresetFromProject() {
        videoResolutionPreset = detectedVideoResolutionPreset
    }

    private func attemptAutomaticRelink(near projectFile: URL) {
        guard missingFrameCount > 0, let oldRoot = project.sourceDirectory else { return }
        let candidate = projectFile.deletingLastPathComponent()
            .appendingPathComponent(oldRoot.lastPathComponent, isDirectory: true)
            .standardizedFileURL
        guard candidate != oldRoot.standardizedFileURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        relinkSourceFiles(to: candidate, automatic: true)
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func scheduleAutosave() {
        guard autosaveEnabled else { return }
        autosaveTask?.cancel()
        let snapshot = project
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? await Task.detached(priority: .utility) {
                try ProjectRecoveryStore.save(snapshot)
            }.value
        }
    }

    private func applyLuminanceBatch(
        _ batch: [LuminanceMeasurement],
        completed: Int,
        total: Int
    ) {
        var updatedProject = project
        for measurement in batch where updatedProject.frames.indices.contains(measurement.index) {
            updatedProject.frames[measurement.index].luminance = measurement.value
        }
        project = updatedProject
        analyzedFrameCount = completed
        progress = Double(completed) / Double(max(total, 1))
        statusMessage = "Analyzing luminance… \(completed) / \(total)"

        let now = Date()
        if autosaveEnabled,
           completed == total || now.timeIntervalSince(analysisLastCheckpoint) >= 2 {
            analysisLastCheckpoint = now
            let snapshot = project
            Task.detached(priority: .utility) {
                try? ProjectRecoveryStore.save(snapshot)
            }
        }
    }

    private func recalculateDeflickerCorrections() {
        deflickerCorrections = AdjustmentEngine.deflickerCorrections(
            luminances: project.frames.map(\.luminance),
            strength: project.deflickerStrength,
            window: project.deflickerWindow
        )
    }

    private func signedEV(_ value: Double) -> String {
        String(format: "%+.2f EV", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
