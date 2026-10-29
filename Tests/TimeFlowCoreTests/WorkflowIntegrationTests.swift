import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TimeFlowApp

final class WorkflowIntegrationTests: XCTestCase {
    @MainActor
    func testBusyStateCanRelayoutInspectorWithoutFocusCycle() {
        let model = ProjectModel(autosaveEnabled: false)
        let host = NSHostingView(rootView: ContentView().environmentObject(model))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        host.layoutSubtreeIfNeeded()

        model.isBusy = true
        host.layoutSubtreeIfNeeded()
        model.isBusy = false
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.frame.size.width, 1_200)
    }

    func testSequenceLoadAnalyzeAndXMPExport() throws {
        let root = temporaryDirectory(named: "sequence")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("frame1.png"), brightness: 0.25)
        try writeGrayPNG(to: root.appendingPathComponent("frame10.png"), brightness: 0.75)
        try writeGrayPNG(to: root.appendingPathComponent("frame2.png"), brightness: 0.50)

        var frames = try ImageSequenceLoader.load(from: root)
        XCTAssertEqual(frames.map(\.displayName), ["frame1.png", "frame2.png", "frame10.png"])
        XCTAssertEqual(frames.first?.metadata.pixelWidth, 64)
        XCTAssertEqual(frames.first?.metadata.pixelHeight, 40)

        let selectedFrames = try ImageSequenceLoader.load(from: [
            root.appendingPathComponent("frame10.png"),
            root.appendingPathComponent("frame1.png")
        ])
        XCTAssertEqual(selectedFrames.map(\.displayName), ["frame1.png", "frame10.png"])

        for index in frames.indices {
            frames[index].luminance = try ImagePipeline.shared.luminance(of: frames[index].url)
        }
        XCTAssertLessThan(frames[0].luminance ?? 1, frames[1].luminance ?? 0)
        XCTAssertLessThan(frames[1].luminance ?? 1, frames[2].luminance ?? 0)

        var project = TimeFlowProject(name: "Integration", sourceDirectory: root, frames: frames)
        project.keyframes = [
            AdjustmentKeyframe(frameIndex: 0, adjustment: Adjustment(exposureEV: 0)),
            AdjustmentKeyframe(frameIndex: 2, adjustment: Adjustment(exposureEV: 1))
        ]
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: frames.map(\.luminance),
            strength: 1,
            window: 1
        )
        let output = root.appendingPathComponent("xmp", isDirectory: true)
        try XMPWriter.export(project: project, corrections: corrections, to: output)

        let sidecars = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xmp" }
        XCTAssertEqual(sidecars.count, 3)
        let middle = try String(contentsOf: output.appendingPathComponent("frame2.xmp"), encoding: .utf8)
        XCTAssertTrue(middle.contains("crs:Exposure2012"))
    }

    func testXMPImportMergeAndBackupPreservesUnknownAdjustments() throws {
        let root = temporaryDirectory(named: "xmp-merge")
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("001.png")
        try writeGrayPNG(to: imageURL, brightness: 0.5)
        let sidecarURL = root.appendingPathComponent("001.xmp")
        let original = XMPWriter.document(
            for: Adjustment(exposureEV: 0.25),
            sourceFile: "001.png"
        ).replacingOccurrences(
            of: "dc:source=",
            with: "crs:Clarity2012=\"17\" custom:KeepMe=\"yes\" xmlns:custom=\"https://example.invalid/custom\" dc:source="
        )
        try Data(original.utf8).write(to: sidecarURL)

        let frames = try ImageSequenceLoader.load(from: root)
        XCTAssertEqual(frames.first?.sourceAdjustment?.exposureEV ?? 0, 0.25, accuracy: 0.0001)
        var project = TimeFlowProject(name: "XMP Merge", sourceDirectory: root, frames: frames)
        project.keyframes = [
            AdjustmentKeyframe(frameIndex: 0, adjustment: Adjustment(exposureEV: 1.5))
        ]
        try XMPWriter.export(project: project, corrections: [0], to: root)

        let merged = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertTrue(merged.contains("crs:Exposure2012=\"+1.5000\""))
        XCTAssertTrue(merged.contains("crs:Clarity2012=\"17\""))
        XCTAssertTrue(merged.contains("custom:KeepMe=\"yes\""))
        let backupDirectory = root.appendingPathComponent(".timeflow-xmp-backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let backup = try String(contentsOf: backups[0], encoding: .utf8)
        XCTAssertTrue(backup.contains("crs:Exposure2012=\"+0.2500\""))
    }

    func testRobustLuminanceRejectsSmallBrightOutlier() throws {
        let root = temporaryDirectory(named: "robust-luminance")
        defer { try? FileManager.default.removeItem(at: root) }

        let clean = root.appendingPathComponent("clean.png")
        let outlier = root.appendingPathComponent("outlier.png")
        try writeGrayPNG(to: clean, brightness: 0.25)
        try writeOutlierPNG(to: outlier, background: 0.25)

        let cleanLuminance = try ImagePipeline.shared.luminance(of: clean)
        let outlierLuminance = try ImagePipeline.shared.luminance(of: outlier)
        XCTAssertEqual(outlierLuminance, cleanLuminance, accuracy: cleanLuminance * 0.05)
    }

    func testRecoveryStoreRoundTripsProject() throws {
        let root = temporaryDirectory(named: "recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("recovery.timeflow")
        var frame = FrameRecord(
            url: root.appendingPathComponent("001.dng"),
            metadata: CaptureMetadata(pixelWidth: 6_000, pixelHeight: 4_000)
        )
        frame.luminance = 0.125
        let project = TimeFlowProject(
            name: "Recovered Project",
            frames: [frame],
            meteorFrameIndices: [0],
            starTrailSettings: StarTrailWorkflowSettings(
                startFrame: 1,
                endFrame: 1,
                gapFillingRadius: 2,
                removeTransientStreaks: true,
                cometEnabled: true,
                cometLength: 120,
                growthVideoFPS: 30,
                growthVideoResolution: .fullHD,
                growthVideoCodec: .hevc,
                growthVideoAutomaticBitRate: false,
                growthVideoBitRateMbps: 18,
                growthVideoColorSpace: .displayP3,
                growthVideoScalingMode: .fit,
                growthVideoCustomWidth: 2_048,
                growthVideoCustomHeight: 858,
                hybridTransitionFrames: 24,
                hybridFinalHoldSeconds: 5
            )
        )

        try ProjectRecoveryStore.save(project, to: destination)
        let recovered = try XCTUnwrap(ProjectRecoveryStore.load(from: destination))

        XCTAssertEqual(recovered, project)
    }

    @MainActor
    func testOpeningProjectRestoresStarTrailAndHybridSettings() throws {
        let root = temporaryDirectory(named: "saved-star-trail-settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("settings.timeflow")
        let frames = (0..<10).map { index in
            FrameRecord(
                url: root.appendingPathComponent("\(index).png"),
                metadata: CaptureMetadata()
            )
        }
        let settings = StarTrailWorkflowSettings(
            startFrame: 3,
            endFrame: 8,
            gapFillingRadius: 3,
            removeTransientStreaks: true,
            cometEnabled: true,
            cometLength: 140,
            growthVideoFPS: 30,
            growthVideoResolution: .verticalFullHD,
            growthVideoCodec: .hevc,
            growthVideoAutomaticBitRate: false,
            growthVideoBitRateMbps: 22,
            growthVideoColorSpace: .displayP3,
            growthVideoScalingMode: .fit,
            growthVideoCustomWidth: 1_600,
            growthVideoCustomHeight: 900,
            hybridTransitionFrames: 36,
            hybridFinalHoldSeconds: 6
        )
        let project = TimeFlowProject(
            name: "Saved Settings",
            frames: frames,
            starTrailSettings: settings
        )
        try ProjectRecoveryStore.save(project, to: destination)

        let model = ProjectModel(autosaveEnabled: false)
        model.openProject(from: destination)

        XCTAssertEqual(model.starTrailSettingsSnapshot, settings)
        XCTAssertEqual(model.project.starTrailSettings, settings)
    }

    func testVideoExporterProducesPlayableMovie() async throws {
        let root = temporaryDirectory(named: "video")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("001.png")
        let second = root.appendingPathComponent("002.png")
        try writeGrayPNG(to: first, brightness: 0.2)
        try writeGrayPNG(to: second, brightness: 0.8)

        var project = TimeFlowProject(
            name: "Video Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        project.exportSettings = ExportSettings(width: 320, height: 192, framesPerSecond: 2)
        let destination = root.appendingPathComponent("result.mov")
        try Data("old-output".utf8).write(to: destination)

        try await VideoExporter.export(
            project: project,
            corrections: [0, 0],
            destination: destination,
            progress: { _ in }
        )

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 1_000)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (firstFrame, _) = try await generator.image(at: .zero)
        let bitmap = NSBitmapImageRep(cgImage: firstFrame)
        let edgeBrightness = try XCTUnwrap(
            bitmap.colorAt(x: 1, y: Int(bitmap.size.height / 2))
        ).brightnessComponent
        XCTAssertGreaterThan(edgeBrightness, 0.1, "Fill mode should not add black side bars")
    }

    func testMarkedMeteorAddsConfiguredHoldToOrdinaryVideo() async throws {
        let root = temporaryDirectory(named: "video-meteor-hold")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.2)
        try writeHorizontalStreakPNG(to: root.appendingPathComponent("002.png"))
        var project = TimeFlowProject(
            name: "Ordinary Meteor Hold Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root),
            meteorFrameIndices: [1]
        )
        project.exportSettings = ExportSettings(
            width: 320,
            height: 192,
            framesPerSecond: 2,
            automaticBitRate: false,
            bitRateMbps: 2,
            meteorHoldSeconds: 0.5
        )
        let destination = root.appendingPathComponent("meteor-hold.mov")

        try await VideoExporter.export(
            project: project,
            corrections: [0, 0],
            destination: destination,
            progress: { _ in }
        )

        let duration = try await AVURLAsset(url: destination).load(.duration)
        XCTAssertEqual(duration.seconds, 1.5, accuracy: 0.05)
    }

    func testH264VideoExporterHonorsSelectedRange() async throws {
        let root = temporaryDirectory(named: "video-h264-range")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.1)
        try writeGrayPNG(to: root.appendingPathComponent("002.png"), brightness: 0.5)
        try writeGrayPNG(to: root.appendingPathComponent("003.png"), brightness: 0.9)
        var project = TimeFlowProject(
            name: "H264 Range Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        project.exportSettings = ExportSettings(
            width: 320,
            height: 192,
            framesPerSecond: 2,
            codec: .h264,
            automaticBitRate: false,
            bitRateMbps: 2,
            colorSpace: .rec709,
            startFrame: 2,
            endFrame: 3
        )
        let destination = root.appendingPathComponent("range.mov")

        try await VideoExporter.export(
            project: project,
            corrections: [0, 0, 0],
            destination: destination,
            progress: { _ in }
        )

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
    }

    func testCancelledVideoExportPreservesExistingOutput() async throws {
        let root = temporaryDirectory(named: "video-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.5)
        var project = TimeFlowProject(
            name: "Cancelled Video",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        project.exportSettings = ExportSettings(width: 320, height: 192, codec: .h264)
        let destination = root.appendingPathComponent("cancelled.mov")
        let original = Data("preserve-existing-output".utf8)
        try original.write(to: destination)
        let task = Task {
            try await VideoExporter.export(
                project: project,
                corrections: [0],
                destination: destination,
                progress: { _ in }
            )
        }
        task.cancel()

        do {
            try await task.value
            XCTFail("Cancelled video export unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testStarTrailExporterUsesLightenStacking() throws {
        let root = temporaryDirectory(named: "star-trail")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeHalfWhitePNG(to: root.appendingPathComponent("001.png"), whiteOnLeft: true)
        try writeHalfWhitePNG(to: root.appendingPathComponent("002.png"), whiteOnLeft: false)
        let project = TimeFlowProject(
            name: "Star Trail Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("stacked.tiff")
        var finalProgress = 0.0

        try StarTrailExporter.export(project: project, destination: destination) {
            finalProgress = $0
        }

        XCTAssertEqual(finalProgress, 1, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let luminance = try ImagePipeline.shared.luminance(of: destination)
        XCTAssertGreaterThan(luminance, 0.9)
    }

    func testStarTrailExporterAppliesKeyframesAndDeflickerCorrections() throws {
        let root = temporaryDirectory(named: "star-trail-adjustments")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.2)
        var project = TimeFlowProject(
            name: "Adjusted Star Trail",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        project.keyframes = [
            AdjustmentKeyframe(frameIndex: 0, adjustment: Adjustment(exposureEV: 0.5))
        ]
        let baselineDestination = root.appendingPathComponent("baseline.tiff")
        var baselineProject = project
        baselineProject.keyframes = []
        try StarTrailExporter.export(
            project: baselineProject,
            destination: baselineDestination,
            progress: { _ in }
        )

        let destination = root.appendingPathComponent("adjusted.tiff")
        try StarTrailExporter.export(
            project: project,
            corrections: [0.5],
            destination: destination,
            progress: { _ in }
        )

        let baselineBitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: baselineDestination)))
        let baselineBrightness = try XCTUnwrap(baselineBitmap.colorAt(x: 32, y: 20)).brightnessComponent
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        let brightness = try XCTUnwrap(bitmap.colorAt(x: 32, y: 20)).brightnessComponent
        XCTAssertGreaterThan(brightness, baselineBrightness + 0.05)
    }

    func testStarTrailRangeUsesOnlySelectedFrames() throws {
        let root = temporaryDirectory(named: "star-trail-range")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeHalfWhitePNG(to: root.appendingPathComponent("001.png"), whiteOnLeft: true)
        try writeHalfWhitePNG(to: root.appendingPathComponent("002.png"), whiteOnLeft: false)
        let project = TimeFlowProject(
            name: "Range Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("range.tiff")
        try StarTrailExporter.export(
            project: project,
            options: StarTrailOptions(startIndex: 0, endIndex: 0),
            destination: destination,
            progress: { _ in }
        )

        let luminance = try ImagePipeline.shared.luminance(of: destination)
        XCTAssertGreaterThan(luminance, 0.4)
        XCTAssertLessThan(luminance, 0.65)
    }

    func testStarTrailCometTailFadesOlderFrames() throws {
        let root = temporaryDirectory(named: "star-trail-comet")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 1)
        try writeGrayPNG(to: root.appendingPathComponent("002.png"), brightness: 0)
        let project = TimeFlowProject(
            name: "Comet Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("comet.tiff")
        try StarTrailExporter.export(
            project: project,
            options: StarTrailOptions(cometTailLength: 10),
            destination: destination,
            progress: { _ in }
        )

        let luminance = try ImagePipeline.shared.luminance(of: destination)
        XCTAssertGreaterThan(luminance, 0.5)
        XCTAssertLessThan(luminance, 0.9)
    }

    func testStarTrailGapFillingExpandsShortGaps() throws {
        let root = temporaryDirectory(named: "star-trail-gap")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeHorizontalStreakPNG(to: root.appendingPathComponent("001.png"))
        let project = TimeFlowProject(
            name: "Gap Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let plain = root.appendingPathComponent("plain.tiff")
        let filled = root.appendingPathComponent("filled.tiff")
        try StarTrailExporter.export(
            project: project,
            destination: plain,
            progress: { _ in }
        )
        try StarTrailExporter.export(
            project: project,
            options: StarTrailOptions(gapFillingRadius: 2),
            destination: filled,
            progress: { _ in }
        )

        let plainLuminance = try ImagePipeline.shared.luminance(of: plain)
        let filledLuminance = try ImagePipeline.shared.luminance(of: filled)
        XCTAssertGreaterThan(filledLuminance, plainLuminance)
    }

    func testStarTrailTransientRejectionRemovesSingleFrameStreak() throws {
        let root = temporaryDirectory(named: "star-trail-rejection")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0)
        try writeHorizontalStreakPNG(to: root.appendingPathComponent("002.png"))
        try writeGrayPNG(to: root.appendingPathComponent("003.png"), brightness: 0)
        let project = TimeFlowProject(
            name: "Rejection Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("cleaned.tiff")
        try StarTrailExporter.export(
            project: project,
            options: StarTrailOptions(removeTransientStreaks: true),
            destination: destination,
            progress: { _ in }
        )

        let luminance = try ImagePipeline.shared.luminance(of: destination)
        XCTAssertLessThan(luminance, 0.02)
    }

    func testMarkedMeteorBypassesTransientStreakRejection() throws {
        let root = temporaryDirectory(named: "star-trail-meteor-preservation")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0)
        try writeHorizontalStreakPNG(to: root.appendingPathComponent("002.png"))
        try writeGrayPNG(to: root.appendingPathComponent("003.png"), brightness: 0)
        let project = TimeFlowProject(
            name: "Meteor Preservation Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root),
            meteorFrameIndices: [1]
        )
        let destination = root.appendingPathComponent("preserved.tiff")
        try StarTrailExporter.export(
            project: project,
            options: StarTrailOptions(
                removeTransientStreaks: true,
                preservedTransientFrameIndices: [1]
            ),
            destination: destination,
            progress: { _ in }
        )

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        let streak = try XCTUnwrap(bitmap.colorAt(x: 32, y: 20))
        XCTAssertGreaterThan(streak.brightnessComponent, 0.9)
    }

    func testStarTrailGrowthVideoProducesPlayableMovie() throws {
        let root = temporaryDirectory(named: "star-trail-video")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeHalfWhitePNG(to: root.appendingPathComponent("001.png"), whiteOnLeft: true)
        try writeHalfWhitePNG(to: root.appendingPathComponent("002.png"), whiteOnLeft: false)
        let project = TimeFlowProject(
            name: "Growth Video Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("growth.mov")
        try StarTrailVideoExporter.export(
            project: project,
            options: StarTrailOptions(),
            settings: StarTrailVideoSettings(
                resolutionPreset: .fullHD,
                framesPerSecond: 2,
                codec: .h264,
                automaticBitRate: false,
                bitRateMbps: 2,
                colorSpace: .displayP3
            ),
            destination: destination,
            progress: { _ in }
        )

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertGreaterThan(values.fileSize ?? 0, 500)
        let asset = AVURLAsset(url: destination)
        let expectation = expectation(description: "Read growth video")
        Task {
            let duration = try await asset.load(.duration)
            XCTAssertEqual(duration.seconds, 1, accuracy: 0.05)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size.width, 1_920)
            XCTAssertEqual(size.height, 1_080)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_H264)
            let extensions = try XCTUnwrap(
                CMFormatDescriptionGetExtensions(description)
            ) as NSDictionary
            XCTAssertEqual(
                extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
                kCVImageBufferColorPrimaries_P3_D65 as String
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testMarkedMeteorAddsConfiguredHoldToGrowthVideo() async throws {
        let root = temporaryDirectory(named: "star-trail-meteor-hold")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.2)
        try writeHorizontalStreakPNG(to: root.appendingPathComponent("002.png"))
        let project = TimeFlowProject(
            name: "Meteor Hold Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root),
            meteorFrameIndices: [1]
        )
        let destination = root.appendingPathComponent("meteor-hold.mov")
        try StarTrailVideoExporter.export(
            project: project,
            options: StarTrailOptions(
                preservedTransientFrameIndices: [1],
                meteorHoldSeconds: 0.5
            ),
            settings: StarTrailVideoSettings(
                resolutionPreset: .source,
                framesPerSecond: 2,
                codec: .h264,
                automaticBitRate: false,
                bitRateMbps: 2
            ),
            destination: destination,
            progress: { _ in }
        )

        let duration = try await AVURLAsset(url: destination).load(.duration)
        XCTAssertEqual(duration.seconds, 1.5, accuracy: 0.05)
    }

    func testStarTrailGrowthVideoSupportsProRes422LT() throws {
        let root = temporaryDirectory(named: "star-trail-video-prores")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeHalfWhitePNG(to: root.appendingPathComponent("001.png"), whiteOnLeft: true)
        try writeHalfWhitePNG(to: root.appendingPathComponent("002.png"), whiteOnLeft: false)
        let project = TimeFlowProject(
            name: "ProRes Growth Video Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        let destination = root.appendingPathComponent("growth-prores.mov")
        try StarTrailVideoExporter.export(
            project: project,
            options: StarTrailOptions(),
            settings: StarTrailVideoSettings(
                resolutionPreset: .source,
                framesPerSecond: 2,
                codec: .proRes422LT
            ),
            destination: destination,
            progress: { _ in }
        )

        let asset = AVURLAsset(url: destination)
        let expectation = expectation(description: "Read ProRes growth video")
        Task {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let description = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                kCMVideoCodecType_AppleProRes422LT
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testStarTrailVideoDefaultsAndAutomaticBitrates() {
        let defaults = StarTrailVideoSettings()
        XCTAssertEqual(
            VideoResolutionPreset.allCases,
            [.custom, .source, .hd, .fullHD, .ultraHD, .verticalFullHD]
        )
        XCTAssertEqual(defaults.resolutionPreset, .ultraHD)
        XCTAssertEqual(defaults.codec, .h264)
        XCTAssertTrue(defaults.automaticBitRate)
        XCTAssertEqual(defaults.colorSpace, .rec709)
        XCTAssertEqual(defaults.scalingMode, .fill)

        let fourK = defaults.outputDimensions(sourceWidth: 7_008, sourceHeight: 4_672)
        XCTAssertEqual(fourK.width, 3_840)
        XCTAssertEqual(fourK.height, 2_160)
        XCTAssertEqual(defaults.resolvedBitRateMbps(width: fourK.width, height: fourK.height), 45)

        var hevc = defaults
        hevc.codec = .hevc
        XCTAssertEqual(hevc.resolvedBitRateMbps(width: fourK.width, height: fourK.height), 28)

        var source = defaults
        source.resolutionPreset = .source
        let sourceSize = source.outputDimensions(sourceWidth: 7_008, sourceHeight: 4_672)
        XCTAssertEqual(sourceSize.width, 7_008)
        XCTAssertEqual(sourceSize.height, 4_672)
        XCTAssertEqual(source.resolvedBitRateMbps(width: sourceSize.width, height: sourceSize.height), 160)

        var custom = defaults
        custom.resolutionPreset = .custom
        custom.customWidth = 2_048
        custom.customHeight = 858
        let customSize = custom.outputDimensions(sourceWidth: 7_008, sourceHeight: 4_672)
        XCTAssertEqual(customSize.width, 2_048)
        XCTAssertEqual(customSize.height, 858)
    }

    func testHybridVideoCombinesTimelapseTrailAndFinalHold() async throws {
        let root = temporaryDirectory(named: "hybrid-video")
        defer { try? FileManager.default.removeItem(at: root) }

        try writeGrayPNG(to: root.appendingPathComponent("001.png"), brightness: 0.15)
        try writeGrayPNG(to: root.appendingPathComponent("002.png"), brightness: 0.25)
        try writeHalfWhitePNG(to: root.appendingPathComponent("003.png"), whiteOnLeft: true)
        try writeHalfWhitePNG(to: root.appendingPathComponent("004.png"), whiteOnLeft: false)
        var project = TimeFlowProject(
            name: "Hybrid Video Test",
            sourceDirectory: root,
            frames: try ImageSequenceLoader.load(from: root)
        )
        project.exportSettings = ExportSettings(
            width: 320,
            height: 192,
            framesPerSecond: 2,
            codec: .h264,
            automaticBitRate: false,
            bitRateMbps: 2,
            colorSpace: .rec709,
            startFrame: 1,
            endFrame: 3
        )
        project.meteorFrameIndices = [0]
        let destination = root.appendingPathComponent("hybrid.mov")

        try await HybridVideoExporter.export(
            project: project,
            corrections: [0, 0, 0, 0],
            settings: HybridVideoSettings(
                transitionFrames: 2,
                finalHoldSeconds: 1
            ),
            starTrailOptions: StarTrailOptions(startIndex: 2, endIndex: 3),
            destination: destination,
            progress: { _ in }
        )

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3.5, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 192)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetPresentationTimeStamp(sample).isValid,
               CMSampleBufferGetNumSamples(sample) > 0 {
                sampleCount += 1
            }
        }
        XCTAssertEqual(sampleCount, 7)
        XCTAssertEqual(reader.status, .completed)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (finalImage, _) = try await generator.image(at: CMTime(value: 6, timescale: 2))
        let bitmap = NSBitmapImageRep(cgImage: finalImage)
        let leftBrightness = try XCTUnwrap(bitmap.colorAt(x: 80, y: 96)).brightnessComponent
        let rightBrightness = try XCTUnwrap(bitmap.colorAt(x: 240, y: 96)).brightnessComponent
        XCTAssertGreaterThan(leftBrightness, 0.75)
        XCTAssertGreaterThan(rightBrightness, 0.75)
    }

    func testLuminanceAnalyzerBoundsConcurrencyAndPreservesOrder() async throws {
        let tracker = AnalysisConcurrencyTracker()
        let urls = (0..<1_000).map { URL(fileURLWithPath: "/virtual/\($0).png") }
        let results = try await LuminanceAnalyzer.analyze(
            urls: urls,
            maxConcurrent: 4,
            batchSize: 37,
            progress: nil
        ) { url in
            await tracker.begin()
            await Task.yield()
            await tracker.end()
            return Double(url.deletingPathExtension().lastPathComponent)!
        }

        XCTAssertEqual(results.count, 1_000)
        XCTAssertEqual(results[0], 0)
        XCTAssertEqual(results[527], 527)
        XCTAssertEqual(results[999], 999)
        let maximumConcurrency = await tracker.maximum
        XCTAssertLessThanOrEqual(maximumConcurrency, 4)
        XCTAssertGreaterThan(maximumConcurrency, 1)
    }

    func testLuminanceAnalyzerCanBeCancelled() async throws {
        let urls = (0..<100).map { URL(fileURLWithPath: "/virtual/\($0).png") }
        let task = Task {
            try await LuminanceAnalyzer.analyze(
                urls: urls,
                maxConcurrent: 3,
                batchSize: 8,
                progress: nil
            ) { _ in
                try await Task.sleep(for: .milliseconds(100))
                return 0.5
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled analysis unexpectedly completed")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testThumbnailCachePersistsAndInvalidatesChangedSource() async throws {
        let root = temporaryDirectory(named: "thumbnail-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        try writeGrayPNG(to: source, brightness: 0.25)
        let cache = ThumbnailCache(cacheDirectory: cacheDirectory, maxBytes: 2 * 1_024 * 1_024)

        _ = try await cache.image(for: source, maxPixelSize: 1_400)
        let firstCount = try await cache.cacheFileCount()
        XCTAssertEqual(firstCount, 1)
        _ = try await cache.image(for: source, maxPixelSize: 1_400)
        let cachedCount = try await cache.cacheFileCount()
        XCTAssertEqual(cachedCount, 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: source.path
        )
        _ = try await cache.image(for: source, maxPixelSize: 1_400)
        let invalidatedCount = try await cache.cacheFileCount()
        XCTAssertEqual(invalidatedCount, 2)
    }

    func testFileRelinkerPreservesRelativePathAndFrameState() throws {
        let root = temporaryDirectory(named: "relink-relative")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old-sequence", isDirectory: true)
        let newRoot = root.appendingPathComponent("new-sequence", isDirectory: true)
        let oldSubfolder = oldRoot.appendingPathComponent("night-1", isDirectory: true)
        let newSubfolder = newRoot.appendingPathComponent("night-1", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSubfolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newSubfolder, withIntermediateDirectories: true)

        let oldImage = oldSubfolder.appendingPathComponent("001.png")
        let newImage = newSubfolder.appendingPathComponent("001.png")
        try writeGrayPNG(to: oldImage, brightness: 0.25)
        var frames = try ImageSequenceLoader.load(from: [oldImage])
        frames[0].luminance = 0.123
        let originalID = frames[0].id
        try writeGrayPNG(to: newImage, brightness: 0.75)
        try FileManager.default.removeItem(at: oldImage)
        let project = TimeFlowProject(name: "Moved", sourceDirectory: oldRoot, frames: frames)

        let result = try FileRelinker.relink(project: project, to: newRoot)

        XCTAssertEqual(result.relinkedCount, 1)
        XCTAssertEqual(result.remainingMissingCount, 0)
        XCTAssertEqual(result.ambiguousCount, 0)
        XCTAssertEqual(result.project.frames[0].url.standardizedFileURL, newImage.standardizedFileURL)
        XCTAssertEqual(result.project.frames[0].id, originalID)
        XCTAssertEqual(result.project.frames[0].luminance, 0.123)
        XCTAssertEqual(result.project.frames[0].metadata.pixelWidth, 64)
    }

    func testFileRelinkerUsesUniqueFilenameFallback() throws {
        let root = temporaryDirectory(named: "relink-fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old", isDirectory: true)
        let newRoot = root.appendingPathComponent("new", isDirectory: true)
        let relocatedFolder = newRoot.appendingPathComponent("different-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: relocatedFolder, withIntermediateDirectories: true)
        let relocated = relocatedFolder.appendingPathComponent("unique.png")
        try writeGrayPNG(to: relocated, brightness: 0.5)
        let missing = FrameRecord(
            url: oldRoot.appendingPathComponent("original-layout/unique.png"),
            metadata: CaptureMetadata()
        )
        let project = TimeFlowProject(name: "Fallback", sourceDirectory: oldRoot, frames: [missing])

        let result = try FileRelinker.relink(project: project, to: newRoot)

        XCTAssertEqual(result.relinkedCount, 1)
        XCTAssertEqual(result.remainingMissingCount, 0)
        XCTAssertEqual(result.project.frames[0].url.standardizedFileURL, relocated.standardizedFileURL)
    }

    func testFileRelinkerDoesNotGuessAmbiguousFilenames() throws {
        let root = temporaryDirectory(named: "relink-ambiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old", isDirectory: true)
        let newRoot = root.appendingPathComponent("new", isDirectory: true)
        let firstFolder = newRoot.appendingPathComponent("a", isDirectory: true)
        let secondFolder = newRoot.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try writeGrayPNG(to: firstFolder.appendingPathComponent("001.png"), brightness: 0.25)
        try writeGrayPNG(to: secondFolder.appendingPathComponent("001.png"), brightness: 0.75)
        let originalURL = oldRoot.appendingPathComponent("missing/001.png")
        let project = TimeFlowProject(
            name: "Ambiguous",
            sourceDirectory: oldRoot,
            frames: [FrameRecord(url: originalURL, metadata: CaptureMetadata())]
        )

        let result = try FileRelinker.relink(project: project, to: newRoot)

        XCTAssertEqual(result.relinkedCount, 0)
        XCTAssertEqual(result.remainingMissingCount, 1)
        XCTAssertEqual(result.ambiguousCount, 1)
        XCTAssertEqual(result.project.frames[0].url, originalURL)
    }

    private func temporaryDirectory(named component: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("timeflow-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeGrayPNG(to url: URL, brightness: CGFloat) throws {
        let width = 64
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create test image context")
            return
        }
        context.setFillColor(red: brightness, green: brightness, blue: brightness, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            XCTFail("Could not create PNG destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeHalfWhitePNG(to url: URL, whiteOnLeft: Bool) throws {
        let width = 64
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create star trail test context")
            return
        }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: whiteOnLeft ? 0 : width / 2, y: 0, width: width / 2, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            XCTFail("Could not create star trail test PNG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeHorizontalStreakPNG(to url: URL) throws {
        let width = 64
        let height = 40
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create streak test context")
            return
        }
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 2, y: 18, width: width - 4, height: 4))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            XCTFail("Could not create streak test PNG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeOutlierPNG(to url: URL, background: CGFloat) throws {
        let width = 100
        let height = 60
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create luminance outlier context")
            return
        }
        context.setFillColor(red: background, green: background, blue: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 5, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            XCTFail("Could not create luminance outlier PNG")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private actor AnalysisConcurrencyTracker {
    private var current = 0
    private(set) var maximum = 0

    func begin() {
        current += 1
        maximum = max(maximum, current)
    }

    func end() {
        current -= 1
    }
}
