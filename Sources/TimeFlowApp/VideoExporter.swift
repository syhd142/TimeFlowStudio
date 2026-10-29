import AVFoundation
import CoreVideo
import Foundation

enum VideoExporter {
    static func export(
        project: TimeFlowProject,
        corrections: [Double],
        destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !project.frames.isEmpty else { throw TimeFlowError.noImagesFound }
        let settings = project.exportSettings
        let width = max(2, settings.width / 2 * 2)
        let height = max(2, settings.height / 2 * 2)
        let fps = max(1, settings.framesPerSecond)
        let firstIndex = min(max(settings.startFrame - 1, 0), project.frames.count - 1)
        let requestedLastIndex = settings.endFrame == .max
            ? project.frames.count - 1
            : settings.endFrame - 1
        let lastIndex = min(max(requestedLastIndex, firstIndex), project.frames.count - 1)
        let selectedIndices = Array(firstIndex...lastIndex)
        let markedMeteorIndices = Set(project.meteorFrameIndices ?? [])
        let meteorHoldFrames = max(
            0,
            Int((settings.meteorHoldSeconds * Double(fps)).rounded())
        )
        let markedMeteorCount = selectedIndices.reduce(into: 0) { count, index in
            if markedMeteorIndices.contains(index) { count += 1 }
        }
        let totalOutputFrames = selectedIndices.count + markedMeteorCount * meteorHoldFrames

        let transaction = ExportFileTransaction(destination: destination)
        defer { transaction.cleanup() }

        let writer = try AVAssetWriter(outputURL: transaction.temporaryURL, fileType: .mov)
        let videoSettings = outputSettings(
            for: settings,
            width: width,
            height: height,
            framesPerSecond: fps
        )
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TimeFlowError.videoSetupFailed(
                "The video writer rejected the \(settings.codec.displayName) settings."
            )
        }
        writer.add(input)

        let attributes = pixelBufferAttributes(width: width, height: height)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.startWriting() else {
            throw TimeFlowError.videoSetupFailed(writer.error?.localizedDescription ?? "Unknown AVAssetWriter error")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            let size = CGSize(width: width, height: height)
            var writtenFrameCount = 0
            for index in selectedIndices {
                let repeatCount = 1 + (markedMeteorIndices.contains(index) ? meteorHoldFrames : 0)
                for _ in 0..<repeatCount {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }

                    try autoreleasepool {
                        guard let pool = adaptor.pixelBufferPool else {
                            throw TimeFlowError.videoSetupFailed("No pixel buffer pool was created.")
                        }
                        var optionalBuffer: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
                        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
                            throw TimeFlowError.videoSetupFailed("A video frame buffer could not be allocated.")
                        }

                        try renderFrame(
                            project: project,
                            corrections: corrections,
                            index: index,
                            into: buffer,
                            outputSize: size,
                            colorSpace: settings.colorSpace,
                            scalingMode: settings.scalingMode
                        )

                        let presentationTime = CMTime(
                            value: CMTimeValue(writtenFrameCount),
                            timescale: CMTimeScale(fps)
                        )
                        guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                            throw TimeFlowError.videoAppendFailed(index)
                        }
                    }
                    writtenFrameCount += 1
                    progress(Double(writtenFrameCount) / Double(max(totalOutputFrames, 1)))
                }
            }

            try Task.checkCancellation()
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            if writer.status != .completed {
                throw TimeFlowError.videoSetupFailed(
                    writer.error?.localizedDescription ?? "The writer did not complete."
                )
            }
            try transaction.commit()
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }
    }

    static func outputSettings(
        for settings: ExportSettings,
        width: Int,
        height: Int,
        framesPerSecond: Int
    ) -> [String: Any] {
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codecType(settings.codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProperties(settings.colorSpace)
        ]
        if settings.codec.usesBitRate {
            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: settings.resolvedBitRateMbps(
                    width: width,
                    height: height
                ) * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: max(framesPerSecond * 2, 1)
            ]
            if settings.codec == .h264 {
                compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        return videoSettings
    }

    static func pixelBufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
    }

    static func renderFrame(
        project: TimeFlowProject,
        corrections: [Double],
        index: Int,
        into buffer: CVPixelBuffer,
        outputSize: CGSize,
        colorSpace: VideoColorSpace,
        scalingMode: VideoScalingMode
    ) throws {
        let frame = project.frames[index]
        var adjustment = project.keyframes.isEmpty
            ? (frame.sourceAdjustment ?? .neutral)
            : AdjustmentEngine.adjustment(at: index, keyframes: project.keyframes)
        if corrections.indices.contains(index) {
            adjustment.exposureEV += corrections[index]
        }
        try ImagePipeline.shared.render(
            url: frame.url,
            adjustment: adjustment,
            into: buffer,
            outputSize: outputSize,
            outputColorSpace: colorSpace,
            scalingMode: scalingMode
        )
    }

    static func codecType(_ codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        }
    }

    static func colorProperties(_ colorSpace: VideoColorSpace) -> [String: String] {
        switch colorSpace {
        case .rec709:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        case .displayP3:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
    }
}
