import AVFoundation
import CoreImage
import CoreVideo
import Foundation

enum StarTrailVideoExporter {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func export(
        project: TimeFlowProject,
        corrections: [Double] = [],
        options: StarTrailOptions,
        settings: StarTrailVideoSettings,
        destination: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        let sourceSize = try StarTrailProcessor.outputSize(project: project, options: options)
        let dimensions = settings.outputDimensions(
            sourceWidth: Int(sourceSize.width),
            sourceHeight: Int(sourceSize.height)
        )
        let width = dimensions.width
        let height = dimensions.height
        let fps = max(1, settings.framesPerSecond)
        let outputColorSpace = renderColorSpace(settings.colorSpace)
        let firstProjectIndex = min(max(options.startIndex, 0), project.frames.count - 1)
        let lastProjectIndex = min(max(options.endIndex, firstProjectIndex), project.frames.count - 1)
        let markedMeteorIndices = options.preservedTransientFrameIndices
            .union(project.meteorFrameIndices ?? [])
        let meteorHoldFrames = max(0, Int((options.meteorHoldSeconds * Double(fps)).rounded()))
        let markedMeteorCount = (firstProjectIndex...lastProjectIndex).reduce(into: 0) { count, index in
            if markedMeteorIndices.contains(index) { count += 1 }
        }
        let totalOutputFrames = (lastProjectIndex - firstProjectIndex + 1)
            + markedMeteorCount * meteorHoldFrames
        var writtenFrameCount = 0

        let transaction = ExportFileTransaction(destination: destination)
        defer { transaction.cleanup() }
        let writer = try AVAssetWriter(outputURL: transaction.temporaryURL, fileType: .mov)
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: VideoExporter.codecType(settings.codec),
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoExporter.colorProperties(settings.colorSpace)
        ]
        if settings.codec.usesBitRate {
            let bitRateMbps = settings.resolvedBitRateMbps(width: width, height: height)
            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitRateMbps * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: max(fps * 2, 1)
            ]
            if settings.codec == .h264 {
                compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            outputSettings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TimeFlowError.starTrailFailed(
                "The video writer rejected the \(settings.codec.displayName) growth-video settings."
            )
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.startWriting() else {
            throw TimeFlowError.starTrailFailed(writer.error?.localizedDescription ?? "Growth video could not start.")
        }
        defer {
            if writer.status == .writing {
                input.markAsFinished()
                writer.cancelWriting()
            }
        }
        writer.startSession(atSourceTime: .zero)
        let outputBounds = CGRect(x: 0, y: 0, width: width, height: height)

        try StarTrailProcessor.process(
            project: project,
            corrections: corrections,
            options: options,
            processingSize: CGSize(width: width, height: height),
            scalingMode: settings.scalingMode,
            workingColorSpace: outputColorSpace,
            progress: { _ in },
            onFrame: { image, index in
                try Task.checkCancellation()
                let projectIndex = firstProjectIndex + index
                let repeatCount = 1 + (
                    markedMeteorIndices.contains(projectIndex)
                        ? meteorHoldFrames
                        : 0
                )
                for _ in 0..<repeatCount {
                    while !input.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                        try Task.checkCancellation()
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        throw TimeFlowError.starTrailFailed("No growth-video pixel buffer pool was created.")
                    }
                    var optionalBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
                    guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
                        throw TimeFlowError.starTrailFailed("A growth-video frame buffer could not be allocated.")
                    }
                    context.render(
                        image,
                        to: buffer,
                        bounds: outputBounds,
                        colorSpace: outputColorSpace
                    )
                    let time = CMTime(
                        value: CMTimeValue(writtenFrameCount),
                        timescale: CMTimeScale(fps)
                    )
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        throw TimeFlowError.videoAppendFailed(projectIndex)
                    }
                    writtenFrameCount += 1
                    progress(Double(writtenFrameCount) / Double(max(totalOutputFrames, 1)))
                }
            },
            completion: { _ in }
        )

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw TimeFlowError.starTrailFailed(writer.error?.localizedDescription ?? "Growth video did not complete.")
        }
        try transaction.commit()
    }

    private static func renderColorSpace(_ value: VideoColorSpace) -> CGColorSpace {
        switch value {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709)
                ?? StarTrailProcessor.colorSpace
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
                ?? StarTrailProcessor.colorSpace
        }
    }
}
