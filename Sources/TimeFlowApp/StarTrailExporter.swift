import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum StarTrailProcessor {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])

    static func outputSize(project: TimeFlowProject, options: StarTrailOptions) throws -> CGSize {
        let range = try resolvedRange(project: project, options: options)
        guard let extent = imageExtent(at: project.frames[range.lowerBound].url) else {
            throw TimeFlowError.imageCannotBeDecoded(project.frames[range.lowerBound].url)
        }
        return extent.size
    }

    static func process(
        project: TimeFlowProject,
        corrections: [Double] = [],
        options: StarTrailOptions,
        processingSize: CGSize? = nil,
        scalingMode: VideoScalingMode = .fit,
        workingColorSpace: CGColorSpace = colorSpace,
        progress: @escaping (Double) -> Void,
        onFrame: (CIImage, Int) throws -> Void = { _, _ in },
        completion: (CIImage) throws -> Void
    ) throws {
        let range = try resolvedRange(project: project, options: options)
        let selectedIndices = Array(range)
        let preservedTransientFrameIndices = options.preservedTransientFrameIndices
            .union(project.meteorFrameIndices ?? [])
        guard let firstExtent = imageExtent(at: project.frames[range.lowerBound].url) else {
            throw TimeFlowError.imageCannotBeDecoded(project.frames[range.lowerBound].url)
        }
        let sourceSize = firstExtent.size
        let requestedSize = processingSize ?? sourceSize
        let width = Int(requestedSize.width)
        let height = Int(requestedSize.height)
        guard width > 0, height > 0 else {
            throw TimeFlowError.starTrailFailed("The first selected frame has invalid dimensions.")
        }

        let bytesPerRow = try checkedProduct(width, 4)
        let byteCount = try checkedProduct(bytesPerRow, height)
        guard var accumulatorData = calloc(1, byteCount),
              var workingData = malloc(byteCount) else {
            throw TimeFlowError.starTrailFailed("There is not enough memory for a full-resolution stack.")
        }
        defer {
            free(accumulatorData)
            free(workingData)
        }

        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: .zero, size: size)
        let progressInterval = max(1, selectedIndices.count / 100)

        for (outputIndex, projectIndex) in selectedIndices.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                var current = try preparedImage(
                    project: project,
                    corrections: corrections,
                    index: projectIndex,
                    expectedSourceSize: sourceSize,
                    outputSize: size,
                    scalingMode: scalingMode,
                    frameNumber: projectIndex + 1
                )

                if options.removeTransientStreaks,
                   selectedIndices.count > 1,
                   !preservedTransientFrameIndices.contains(projectIndex) {
                    let previousOffset = outputIndex > 0 ? outputIndex - 1 : outputIndex + 1
                    let nextOffset = outputIndex < selectedIndices.count - 1 ? outputIndex + 1 : outputIndex - 1
                    let previousIndex = selectedIndices[previousOffset]
                    let nextIndex = selectedIndices[nextOffset]
                    let previous = try preparedImage(
                        project: project,
                        corrections: corrections,
                        index: previousIndex,
                        expectedSourceSize: sourceSize,
                        outputSize: size,
                        scalingMode: scalingMode,
                        frameNumber: previousIndex + 1
                    )
                    let next = try preparedImage(
                        project: project,
                        corrections: corrections,
                        index: nextIndex,
                        expectedSourceSize: sourceSize,
                        outputSize: size,
                        scalingMode: scalingMode,
                        frameNumber: nextIndex + 1
                    )
                    current = suppressTransientStreaks(
                        current: current,
                        previous: previous,
                        next: next,
                        supportRadius: options.transientSupportRadius
                    )
                }

                if options.gapFillingRadius > 0 {
                    current = current.applyingFilter(
                        "CIMorphologyMaximum",
                        parameters: [kCIInputRadiusKey: options.gapFillingRadius]
                    )
                }

                var accumulated = bitmapImage(
                    data: accumulatorData,
                    byteCount: byteCount,
                    bytesPerRow: bytesPerRow,
                    size: size,
                    colorSpace: workingColorSpace
                )
                if let cometLength = options.cometTailLength, cometLength > 0 {
                    accumulated = faded(accumulated, tailLength: cometLength)
                }

                let maximum = CIFilter.maximumCompositing()
                maximum.inputImage = current
                maximum.backgroundImage = accumulated
                guard let stacked = maximum.outputImage else {
                    throw TimeFlowError.starTrailFailed("Core Image could not create the Lighten composite.")
                }
                context.render(
                    stacked,
                    toBitmap: workingData,
                    rowBytes: bytesPerRow,
                    bounds: bounds,
                    format: .RGBA8,
                    colorSpace: workingColorSpace
                )
                swap(&accumulatorData, &workingData)

                let output = bitmapImage(
                    data: accumulatorData,
                    byteCount: byteCount,
                    bytesPerRow: bytesPerRow,
                    size: size,
                    colorSpace: workingColorSpace
                )
                try onFrame(output, outputIndex)
            }

            if (outputIndex + 1).isMultiple(of: progressInterval) || outputIndex == selectedIndices.count - 1 {
                progress(Double(outputIndex + 1) / Double(selectedIndices.count))
            }
        }

        let result = bitmapImage(
            data: accumulatorData,
            byteCount: byteCount,
            bytesPerRow: bytesPerRow,
            size: size,
            colorSpace: workingColorSpace
        )
        try completion(result)
    }

    static func suppressTransientStreaks(
        current: CIImage,
        previous: CIImage,
        next: CIImage,
        supportRadius: Int
    ) -> CIImage {
        let neighbors = previous.applyingFilter(
            "CIMaximumCompositing",
            parameters: [kCIInputBackgroundImageKey: next]
        )
        let support = neighbors.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [kCIInputRadiusKey: max(1, supportRadius)]
        )
        let unsupportedBrightness = support.applyingFilter(
            "CISubtractBlendMode",
            parameters: [kCIInputBackgroundImageKey: current]
        )
        let mask = unsupportedBrightness
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.12])
            .applyingFilter("CIMaskToAlpha")
        return neighbors.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: current,
                kCIInputMaskImageKey: mask
            ]
        )
    }

    static func faded(_ image: CIImage, tailLength: Int) -> CIImage {
        let decay = pow(0.02, 1 / Double(max(tailLength, 1)))
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: decay, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: decay, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: decay, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )
    }

    private static func bitmapImage(
        data: UnsafeMutableRawPointer,
        byteCount: Int,
        bytesPerRow: Int,
        size: CGSize,
        colorSpace: CGColorSpace
    ) -> CIImage {
        let bitmapData = Data(bytesNoCopy: data, count: byteCount, deallocator: .none)
        return CIImage(
            bitmapData: bitmapData,
            bytesPerRow: bytesPerRow,
            size: size,
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }

    private static func preparedImage(
        project: TimeFlowProject,
        corrections: [Double],
        index: Int,
        expectedSourceSize: CGSize,
        outputSize: CGSize,
        scalingMode: VideoScalingMode,
        frameNumber: Int
    ) throws -> CIImage {
        let frame = project.frames[index]
        var adjustment = project.keyframes.isEmpty
            ? (frame.sourceAdjustment ?? .neutral)
            : AdjustmentEngine.adjustment(at: index, keyframes: project.keyframes)
        if corrections.indices.contains(index) {
            adjustment.exposureEV += corrections[index]
        }
        let image = try ImagePipeline.shared.adjustedImage(
            url: frame.url,
            adjustment: adjustment
        )
        let extent = image.extent.integral
        guard Int(extent.width) == Int(expectedSourceSize.width),
              Int(extent.height) == Int(expectedSourceSize.height) else {
            throw TimeFlowError.starTrailFailed(
                "Frame \(frameNumber) does not match the first selected frame's dimensions."
            )
        }
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        if Int(outputSize.width) == Int(expectedSourceSize.width),
           Int(outputSize.height) == Int(expectedSourceSize.height) {
            return normalized
        }
        return ImagePipeline.shared.fittedImage(
            normalized,
            outputSize: outputSize,
            scalingMode: scalingMode
        )
    }

    private static func sourceImage(at url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    private static func imageExtent(at url: URL) -> CGRect? {
        autoreleasepool { sourceImage(at: url)?.extent.integral }
    }

    private static func resolvedRange(
        project: TimeFlowProject,
        options: StarTrailOptions
    ) throws -> ClosedRange<Int> {
        guard !project.frames.isEmpty else { throw TimeFlowError.noImagesFound }
        let lower = min(max(options.startIndex, 0), project.frames.count - 1)
        let upper = min(max(options.endIndex, lower), project.frames.count - 1)
        return lower...upper
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw TimeFlowError.starTrailFailed("The image dimensions are too large to stack safely.")
        }
        return result
    }
}

enum StarTrailExporter {
    static func export(
        project: TimeFlowProject,
        corrections: [Double] = [],
        options: StarTrailOptions = StarTrailOptions(),
        destination: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        let transaction = ExportFileTransaction(destination: destination)
        defer { transaction.cleanup() }
        try StarTrailProcessor.process(
            project: project,
            corrections: corrections,
            options: options,
            progress: progress
        ) { result in
            try StarTrailProcessor.context.writeTIFFRepresentation(
                of: result,
                to: transaction.temporaryURL,
                format: .RGBA8,
                colorSpace: StarTrailProcessor.colorSpace,
                options: [:]
            )
        }
        try transaction.commit()
    }
}
