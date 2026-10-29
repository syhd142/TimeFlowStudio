import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

enum HybridVideoExporter {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])

    static func export(
        project: TimeFlowProject,
        corrections: [Double],
        settings hybridSettings: HybridVideoSettings,
        starTrailOptions: StarTrailOptions,
        destination: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !project.frames.isEmpty else { throw TimeFlowError.noImagesFound }
        let videoSettings = project.exportSettings
        let width = max(2, videoSettings.width / 2 * 2)
        let height = max(2, videoSettings.height / 2 * 2)
        let fps = max(1, videoSettings.framesPerSecond)
        let videoFirstIndex = min(max(videoSettings.startFrame - 1, 0), project.frames.count - 1)
        let requestedVideoLastIndex = videoSettings.endFrame == .max
            ? project.frames.count - 1
            : videoSettings.endFrame - 1
        let videoLastIndex = min(
            max(requestedVideoLastIndex, videoFirstIndex),
            project.frames.count - 1
        )
        let starStartIndex = min(max(starTrailOptions.startIndex, 0), project.frames.count - 1)
        let starEndIndex = min(
            max(starTrailOptions.endIndex, starStartIndex),
            project.frames.count - 1
        )
        guard videoLastIndex == starStartIndex else {
            throw TimeFlowError.videoSetupFailed(
                "Video End frame must match Star trail Start frame."
            )
        }
        let normalIndices = Array(videoFirstIndex..<starStartIndex)
        let starIndices = Array(starStartIndex...starEndIndex)
        let selectedIndices = normalIndices + starIndices
        let normalFrameCount = normalIndices.count
        let markedMeteorIndices = starTrailOptions.preservedTransientFrameIndices
            .union(project.meteorFrameIndices ?? [])
        let holdFrames = max(0, hybridSettings.finalHoldSeconds) * fps
        let meteorHoldFrames = max(
            0,
            Int((starTrailOptions.meteorHoldSeconds * Double(fps)).rounded())
        )
        let markedMeteorCount = selectedIndices.reduce(into: 0) { count, index in
            if markedMeteorIndices.contains(index) { count += 1 }
        }
        let totalOutputFrames = selectedIndices.count
            + markedMeteorCount * meteorHoldFrames
            + holdFrames
        let outputSize = CGSize(width: width, height: height)
        let outputBounds = CGRect(origin: .zero, size: outputSize)
        let outputColorSpace = renderColorSpace(videoSettings.colorSpace)

        let transaction = ExportFileTransaction(destination: destination)
        defer { transaction.cleanup() }

        let writer = try AVAssetWriter(outputURL: transaction.temporaryURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: VideoExporter.outputSettings(
                for: videoSettings,
                width: width,
                height: height,
                framesPerSecond: fps
            )
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw TimeFlowError.videoSetupFailed(
                "The video writer rejected the hybrid \(videoSettings.codec.displayName) settings."
            )
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: VideoExporter.pixelBufferAttributes(
                width: width,
                height: height
            )
        )
        guard writer.startWriting() else {
            throw TimeFlowError.videoSetupFailed(
                writer.error?.localizedDescription ?? "The hybrid video writer could not start."
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            let currentBuffer = try makePixelBuffer(width: width, height: height)
            let neighborBeforeBuffer = starTrailOptions.removeTransientStreaks
                ? try makePixelBuffer(width: width, height: height)
                : nil
            let neighborAfterBuffer = starTrailOptions.removeTransientStreaks
                ? try makePixelBuffer(width: width, height: height)
                : nil
            var accumulatorBuffer = try makePixelBuffer(width: width, height: height)
            var workingBuffer = try makePixelBuffer(width: width, height: height)
            var hasAccumulator = false
            var writtenFrameCount = 0

            for (position, projectIndex) in selectedIndices.enumerated() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }

                try autoreleasepool {
                    let outputBuffer = try makeWriterBuffer(adaptor)
                    var repeatImage: CIImage?
                    if position < normalFrameCount {
                        try VideoExporter.renderFrame(
                            project: project,
                            corrections: corrections,
                            index: projectIndex,
                            into: outputBuffer,
                            outputSize: outputSize,
                            colorSpace: videoSettings.colorSpace,
                            scalingMode: videoSettings.scalingMode
                        )
                        if markedMeteorIndices.contains(projectIndex) {
                            repeatImage = image(from: outputBuffer, colorSpace: outputColorSpace)
                        }
                    } else {
                        try VideoExporter.renderFrame(
                            project: project,
                            corrections: corrections,
                            index: projectIndex,
                            into: currentBuffer,
                            outputSize: outputSize,
                            colorSpace: videoSettings.colorSpace,
                            scalingMode: videoSettings.scalingMode
                        )
                        let renderedCurrent = image(
                            from: currentBuffer,
                            colorSpace: outputColorSpace
                        )
                        var stackInput = renderedCurrent

                        if starTrailOptions.removeTransientStreaks,
                           !markedMeteorIndices.contains(projectIndex),
                           starStartIndex < starEndIndex,
                           let neighborBeforeBuffer,
                           let neighborAfterBuffer {
                            let beforeIndex = projectIndex > starStartIndex
                                ? projectIndex - 1
                                : projectIndex + 1
                            let afterIndex = projectIndex < starEndIndex
                                ? projectIndex + 1
                                : projectIndex - 1
                            try VideoExporter.renderFrame(
                                project: project,
                                corrections: corrections,
                                index: beforeIndex,
                                into: neighborBeforeBuffer,
                                outputSize: outputSize,
                                colorSpace: videoSettings.colorSpace,
                                scalingMode: videoSettings.scalingMode
                            )
                            try VideoExporter.renderFrame(
                                project: project,
                                corrections: corrections,
                                index: afterIndex,
                                into: neighborAfterBuffer,
                                outputSize: outputSize,
                                colorSpace: videoSettings.colorSpace,
                                scalingMode: videoSettings.scalingMode
                            )
                            stackInput = StarTrailProcessor.suppressTransientStreaks(
                                current: renderedCurrent,
                                previous: image(from: neighborBeforeBuffer, colorSpace: outputColorSpace),
                                next: image(from: neighborAfterBuffer, colorSpace: outputColorSpace),
                                supportRadius: starTrailOptions.transientSupportRadius
                            )
                        }

                        if starTrailOptions.gapFillingRadius > 0 {
                            stackInput = stackInput.applyingFilter(
                                "CIMorphologyMaximum",
                                parameters: [kCIInputRadiusKey: starTrailOptions.gapFillingRadius]
                            )
                        }

                        if !hasAccumulator {
                            context.render(
                                stackInput,
                                to: accumulatorBuffer,
                                bounds: outputBounds,
                                colorSpace: outputColorSpace
                            )
                            hasAccumulator = true
                        } else {
                            var previousStack = image(
                                from: accumulatorBuffer,
                                colorSpace: outputColorSpace
                            )
                            if let tailLength = starTrailOptions.cometTailLength, tailLength > 0 {
                                previousStack = StarTrailProcessor.faded(
                                    previousStack,
                                    tailLength: tailLength
                                )
                            }
                            let maximum = CIFilter.maximumCompositing()
                            maximum.inputImage = stackInput
                            maximum.backgroundImage = previousStack
                            guard let accumulated = maximum.outputImage else {
                                throw TimeFlowError.starTrailFailed(
                                    "Core Image could not build the hybrid star trail."
                                )
                            }
                            context.render(
                                accumulated,
                                to: workingBuffer,
                                bounds: outputBounds,
                                colorSpace: outputColorSpace
                            )
                            swap(&accumulatorBuffer, &workingBuffer)
                        }

                        let accumulated = image(
                            from: accumulatorBuffer,
                            colorSpace: outputColorSpace
                        )
                        let starPosition = projectIndex - starStartIndex
                        let transitionFrames = max(0, hybridSettings.transitionFrames)
                        let outputImage: CIImage
                        if transitionFrames > 0, starPosition < transitionFrames {
                            let amount = min(
                                Double(starPosition + 1) / Double(transitionFrames),
                                1
                            )
                            outputImage = renderedCurrent.applyingFilter(
                                "CIDissolveTransition",
                                parameters: [
                                    "inputTargetImage": accumulated,
                                    "inputTime": amount
                                ]
                            )
                        } else {
                            outputImage = accumulated
                        }
                        context.render(
                            outputImage,
                            to: outputBuffer,
                            bounds: outputBounds,
                            colorSpace: outputColorSpace
                        )
                        repeatImage = outputImage
                    }

                    let presentationTime = CMTime(
                        value: CMTimeValue(writtenFrameCount),
                        timescale: CMTimeScale(fps)
                    )
                    guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                        throw TimeFlowError.videoAppendFailed(projectIndex)
                    }
                    writtenFrameCount += 1

                    let extraMeteorFrames = markedMeteorIndices.contains(projectIndex)
                        ? meteorHoldFrames
                        : 0
                    if let repeatImage, extraMeteorFrames > 0 {
                        for _ in 0..<extraMeteorFrames {
                            while !input.isReadyForMoreMediaData {
                                Thread.sleep(forTimeInterval: 0.005)
                                try Task.checkCancellation()
                            }
                            let repeatedBuffer = try makeWriterBuffer(adaptor)
                            context.render(
                                repeatImage,
                                to: repeatedBuffer,
                                bounds: outputBounds,
                                colorSpace: outputColorSpace
                            )
                            let repeatedTime = CMTime(
                                value: CMTimeValue(writtenFrameCount),
                                timescale: CMTimeScale(fps)
                            )
                            guard adaptor.append(repeatedBuffer, withPresentationTime: repeatedTime) else {
                                throw TimeFlowError.videoAppendFailed(projectIndex)
                            }
                            writtenFrameCount += 1
                        }
                    }
                }
                progress(Double(writtenFrameCount) / Double(totalOutputFrames))
            }

            if holdFrames > 0, hasAccumulator {
                for _ in 0..<holdFrames {
                    try Task.checkCancellation()
                    while !input.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    try autoreleasepool {
                        let outputBuffer = try makeWriterBuffer(adaptor)
                        context.render(
                            image(from: accumulatorBuffer, colorSpace: outputColorSpace),
                            to: outputBuffer,
                            bounds: outputBounds,
                            colorSpace: outputColorSpace
                        )
                        let presentationTime = CMTime(
                            value: CMTimeValue(writtenFrameCount),
                            timescale: CMTimeScale(fps)
                        )
                        guard adaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                            throw TimeFlowError.videoAppendFailed(starEndIndex)
                        }
                        writtenFrameCount += 1
                    }
                    progress(Double(writtenFrameCount) / Double(totalOutputFrames))
                }
            }

            try Task.checkCancellation()
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else {
                throw TimeFlowError.videoSetupFailed(
                    writer.error?.localizedDescription ?? "The hybrid video writer did not complete."
                )
            }
            try transaction.commit()
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        var attributes = VideoExporter.pixelBufferAttributes(width: width, height: height)
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw TimeFlowError.videoSetupFailed("A hybrid working buffer could not be allocated.")
        }
        return buffer
    }

    private static func makeWriterBuffer(
        _ adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else {
            throw TimeFlowError.videoSetupFailed("No hybrid video pixel buffer pool was created.")
        }
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw TimeFlowError.videoSetupFailed("A hybrid output frame could not be allocated.")
        }
        return buffer
    }

    private static func image(
        from buffer: CVPixelBuffer,
        colorSpace: CGColorSpace
    ) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
    }

    private static func renderColorSpace(_ value: VideoColorSpace) -> CGColorSpace {
        switch value {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }
}
