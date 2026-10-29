import XCTest
@testable import TimeFlowApp

final class AdjustmentEngineTests: XCTestCase {
    func testSmoothKeyframeInterpolation() {
        let left = AdjustmentKeyframe(frameIndex: 0, adjustment: Adjustment(exposureEV: 0))
        let right = AdjustmentKeyframe(frameIndex: 10, adjustment: Adjustment(exposureEV: 2))

        XCTAssertEqual(AdjustmentEngine.adjustment(at: 0, keyframes: [left, right]).exposureEV, 0, accuracy: 0.0001)
        XCTAssertEqual(AdjustmentEngine.adjustment(at: 5, keyframes: [left, right]).exposureEV, 1, accuracy: 0.0001)
        XCTAssertEqual(AdjustmentEngine.adjustment(at: 10, keyframes: [left, right]).exposureEV, 2, accuracy: 0.0001)
    }

    func testKeyframeValuesAreHeldOutsideRange() {
        let keyframe = AdjustmentKeyframe(frameIndex: 4, adjustment: Adjustment(exposureEV: 1.25))
        XCTAssertEqual(AdjustmentEngine.adjustment(at: 0, keyframes: [keyframe]).exposureEV, 1.25)
        XCTAssertEqual(AdjustmentEngine.adjustment(at: 99, keyframes: [keyframe]).exposureEV, 1.25)
    }

    func testDeflickerUsesLogExposureDomain() {
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: [0.5, 0.25, 0.5],
            strength: 1,
            window: 3
        )
        XCTAssertEqual(corrections[0], 0, accuracy: 0.0001)
        XCTAssertEqual(corrections[1], 1, accuracy: 0.0001)
        XCTAssertEqual(corrections[2], 0, accuracy: 0.0001)
    }

    func testDeflickerPreservesGradualBrightnessRamp() {
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: [0.10, 0.15, 0.22, 0.32, 0.46, 0.65],
            strength: 1,
            window: 3
        )
        for correction in corrections {
            XCTAssertEqual(correction, 0, accuracy: 0.0001)
        }
    }

    func testDeflickerLeavesMissingMeasurementsNeutral() {
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: [0.5, nil, 0.25, 0.5],
            strength: 1,
            window: 3
        )
        XCTAssertEqual(corrections[1], 0)
        XCTAssertTrue(corrections.allSatisfy(\.isFinite))
    }

    func testWindowOneDisablesTemporalCorrection() {
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: [0.5, 0.25, 0.5],
            strength: 1,
            window: 1
        )
        XCTAssertEqual(corrections, [0, 0, 0])
    }

    func testDeflickerStrengthCanDisableCorrection() {
        let corrections = AdjustmentEngine.deflickerCorrections(
            luminances: [0.5, 0.25, 0.5],
            strength: 0,
            window: 9
        )
        XCTAssertEqual(corrections, [0, 0, 0])
    }

    func testXMPContainsIndependentAdjustmentValues() {
        let xml = XMPWriter.document(
            for: Adjustment(exposureEV: 1.25, temperature: 5_600, tint: -3, contrast: 12, saturation: 7),
            sourceFile: "frame&01.dng"
        )
        XCTAssertTrue(xml.contains("crs:Exposure2012=\"+1.2500\""))
        XCTAssertTrue(xml.contains("crs:Temperature=\"5600\""))
        XCTAssertTrue(xml.contains("dc:source=\"frame&amp;01.dng\""))
    }

    func testLegacyExportSettingsDecodeWithNewDefaults() throws {
        let legacy = Data(#"{"width":1280,"height":720,"framesPerSecond":30}"#.utf8)
        let settings = try JSONDecoder().decode(ExportSettings.self, from: legacy)

        XCTAssertEqual(settings.width, 1_280)
        XCTAssertEqual(settings.height, 720)
        XCTAssertEqual(settings.framesPerSecond, 30)
        XCTAssertEqual(settings.codec, .h264)
        XCTAssertTrue(settings.automaticBitRate)
        XCTAssertEqual(settings.colorSpace, .rec709)
        XCTAssertEqual(settings.scalingMode, .fill)
        XCTAssertEqual(settings.meteorHoldSeconds, 0.5)
        XCTAssertEqual(settings.startFrame, 1)
        XCTAssertEqual(settings.endFrame, .max)
    }

    @MainActor
    func testHybridOutputDescriptionUsesVideoSettings() {
        let model = ProjectModel(autosaveEnabled: false)
        model.project.exportSettings = ExportSettings(
            width: 3_841,
            height: 2_161,
            framesPerSecond: 30,
            codec: .proRes422LT,
            bitRateMbps: 24,
            colorSpace: .rec709,
            startFrame: 1,
            endFrame: 100
        )

        XCTAssertEqual(
            model.hybridVideoOutputDescription,
            "3840 × 2160 · Fill (crop) · Apple ProRes 422 LT · 30 FPS"
        )
    }

    func testVideoBitrateDefaultsToAutomaticAndCanUseManualValue() {
        var settings = ExportSettings(
            width: 3_840,
            height: 2_160,
            framesPerSecond: 25,
            codec: .hevc,
            bitRateMbps: 12
        )
        XCTAssertTrue(settings.automaticBitRate)
        XCTAssertEqual(settings.resolvedBitRateMbps(), 28)

        settings.automaticBitRate = false
        XCTAssertEqual(settings.resolvedBitRateMbps(), 12)
    }

    func testChartSamplerCapsLargeSeriesAndKeepsRequiredPoints() {
        var values = (0..<10_000).map { Optional(Double($0 % 37)) }
        values[4_321] = 10_000

        let samples = ChartSampler.downsample(values, maxPoints: 600, including: 7_777)

        XCTAssertLessThanOrEqual(samples.count, 600)
        XCTAssertEqual(samples.first?.index, 0)
        XCTAssertEqual(samples.last?.index, 9_999)
        XCTAssertTrue(samples.contains { $0.index == 4_321 && $0.value == 10_000 })
        XCTAssertTrue(samples.contains { $0.index == 7_777 })
    }

    @MainActor
    func testUndoRedoRestoresRemovedKeyframe() {
        let model = ProjectModel(autosaveEnabled: false)
        model.project.frames = [
            FrameRecord(url: URL(fileURLWithPath: "/tmp/undo-test.png"), metadata: CaptureMetadata())
        ]
        model.selectFrame(0)
        model.draftAdjustment.exposureEV = 1.25
        model.commitKeyframe()
        XCTAssertEqual(model.project.keyframes.count, 1)

        model.removeKeyframe()
        XCTAssertTrue(model.project.keyframes.isEmpty)
        XCTAssertTrue(model.canUndo)

        model.undo()
        XCTAssertEqual(model.project.keyframes.count, 1)
        XCTAssertEqual(model.project.keyframes[0].adjustment.exposureEV, 1.25, accuracy: 0.0001)
        XCTAssertTrue(model.canRedo)

        model.redo()
        XCTAssertTrue(model.project.keyframes.isEmpty)
    }

    @MainActor
    func testMeteorMarkCanBeUndoneAndRedone() {
        let model = ProjectModel(autosaveEnabled: false)
        model.project.frames = [
            FrameRecord(url: URL(fileURLWithPath: "/tmp/meteor-test.png"), metadata: CaptureMetadata())
        ]
        model.selectFrame(0)

        model.toggleSelectedFrameMeteor()
        XCTAssertTrue(model.isSelectedFrameMarkedAsMeteor)
        XCTAssertEqual(model.meteorFrameCount, 1)

        model.undo()
        XCTAssertFalse(model.isSelectedFrameMarkedAsMeteor)
        model.redo()
        XCTAssertTrue(model.isSelectedFrameMarkedAsMeteor)
    }

    @MainActor
    func testCurveEditIsSingleUndoOperation() {
        let model = ProjectModel(autosaveEnabled: false)
        model.project.frames = [
            FrameRecord(url: URL(fileURLWithPath: "/tmp/curve-test.png"), metadata: CaptureMetadata())
        ]
        model.selectFrame(0)
        model.commitKeyframe()
        let id = model.project.keyframes[0].id

        model.beginKeyframeCurveEdit()
        model.updateKeyframeExposure(id: id, exposureEV: 1)
        model.updateKeyframeExposure(id: id, exposureEV: 2)
        model.endKeyframeCurveEdit()
        XCTAssertEqual(model.project.keyframes[0].adjustment.exposureEV, 2)

        model.undo()
        XCTAssertEqual(model.project.keyframes[0].adjustment.exposureEV, 0)
    }

    @MainActor
    func testEditingEndFrameDoesNotChangeStartFrame() {
        let model = ProjectModel(autosaveEnabled: false)
        model.project.frames = (1...10).map { index in
            FrameRecord(
                url: URL(fileURLWithPath: "/tmp/range-\(index).png"),
                metadata: CaptureMetadata()
            )
        }

        model.starTrailStartFrame = 7
        model.starTrailEndFrame = 3
        model.starTrailEndChanged()
        XCTAssertEqual(model.starTrailStartFrame, 7)
        XCTAssertEqual(model.starTrailEndFrame, 3)
        XCTAssertFalse(model.isStarTrailFrameRangeValid)

        model.project.exportSettings.startFrame = 7
        model.project.exportSettings.endFrame = 3
        model.videoEndChanged()
        XCTAssertEqual(model.project.exportSettings.startFrame, 7)
        XCTAssertEqual(model.project.exportSettings.endFrame, 3)
        XCTAssertFalse(model.isVideoFrameRangeValid)

        model.starTrailEndFrame = 9
        model.starTrailEndChanged()
        model.project.exportSettings.endFrame = 9
        model.videoEndChanged()
        XCTAssertEqual(model.starTrailStartFrame, 7)
        XCTAssertEqual(model.project.exportSettings.startFrame, 7)
        XCTAssertTrue(model.isStarTrailFrameRangeValid)
        XCTAssertTrue(model.isVideoFrameRangeValid)
    }
}
