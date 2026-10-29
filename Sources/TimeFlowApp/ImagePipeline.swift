import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

final class ImagePipeline {
    static let shared = ImagePipeline()

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private init() {}

    func luminance(of url: URL) throws -> Double {
        guard let image = thumbnailCGImage(url: url, maxPixelSize: 256) else {
            throw TimeFlowError.imageCannotBeDecoded(url)
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let bitmap = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TimeFlowError.imageCannotBeDecoded(url)
        }
        bitmap.interpolationQuality = .medium
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let binCount = 512
        let minimumLog = -16.0
        let maximumLog = 0.0
        var counts = [Int](repeating: 0, count: binCount)
        var luminanceSums = [Double](repeating: 0, count: binCount)
        var sampleCount = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = linearChannel(pixels[offset])
            let green = linearChannel(pixels[offset + 1])
            let blue = linearChannel(pixels[offset + 2])
            let luminance = max(0.2126 * red + 0.7152 * green + 0.0722 * blue, 0.000_001)
            let logLuminance = log2(luminance)
            let normalized = (min(max(logLuminance, minimumLog), maximumLog) - minimumLog)
                / (maximumLog - minimumLog)
            let bin = min(Int(normalized * Double(binCount - 1)), binCount - 1)
            counts[bin] += 1
            luminanceSums[bin] += luminance
            sampleCount += 1
        }
        return trimmedArithmeticMean(
            counts: counts,
            luminanceSums: luminanceSums,
            sampleCount: sampleCount,
            trimFraction: 0.10
        )
    }

    func previewCGImage(url: URL, maxPixelSize: Int, adjustment: Adjustment) throws -> CGImage {
        let thumbnail = try decodedThumbnail(url: url, maxPixelSize: maxPixelSize)
        return try previewCGImage(thumbnail: thumbnail, adjustment: adjustment)
    }

    func decodedThumbnail(url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let thumbnail = thumbnailCGImage(url: url, maxPixelSize: maxPixelSize) else {
            throw TimeFlowError.imageCannotBeDecoded(url)
        }
        return thumbnail
    }

    func previewCGImage(thumbnail: CGImage, adjustment: Adjustment) throws -> CGImage {
        let input = CIImage(cgImage: thumbnail)
        let output = apply(adjustment, to: input)
        guard let cgImage = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw TimeFlowError.previewRenderingFailed
        }
        return cgImage
    }

    func render(
        url: URL,
        adjustment: Adjustment,
        into pixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        outputColorSpace: VideoColorSpace = .rec709,
        scalingMode: VideoScalingMode = .fill
    ) throws {
        let adjusted = try adjustedImage(url: url, adjustment: adjustment)
        let widthScale = outputSize.width / adjusted.extent.width
        let heightScale = outputSize.height / adjusted.extent.height
        let scale = scalingMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let scaled = adjusted.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (outputSize.width - scaled.extent.width) / 2 - scaled.extent.minX
        let y = (outputSize.height - scaled.extent.height) / 2 - scaled.extent.minY
        let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
        let background = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))
        let composite = placed.composited(over: background)

        context.render(
            composite,
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: renderColorSpace(outputColorSpace)
        )
    }

    func adjustedImage(url: URL, adjustment: Adjustment) throws -> CIImage {
        guard let input = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw TimeFlowError.imageCannotBeDecoded(url)
        }
        return apply(adjustment, to: input)
    }

    func fittedImage(
        _ image: CIImage,
        outputSize: CGSize,
        scalingMode: VideoScalingMode
    ) -> CIImage {
        let normalized = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        let widthScale = outputSize.width / normalized.extent.width
        let heightScale = outputSize.height / normalized.extent.height
        let scale = scalingMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(
            by: CGAffineTransform(
                translationX: (outputSize.width - scaled.extent.width) / 2,
                y: (outputSize.height - scaled.extent.height) / 2
            )
        )
        let bounds = CGRect(origin: .zero, size: outputSize)
        return placed.composited(over: CIImage(color: .black).cropped(to: bounds))
            .cropped(to: bounds)
    }

    private func renderColorSpace(_ value: VideoColorSpace) -> CGColorSpace {
        switch value {
        case .rec709:
            return CGColorSpace(name: CGColorSpace.itur_709) ?? colorSpace
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3) ?? colorSpace
        }
    }

    private func apply(_ adjustment: Adjustment, to image: CIImage) -> CIImage {
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(adjustment.exposureEV)
        var result = exposure.outputImage ?? image

        let temperature = CIFilter.temperatureAndTint()
        temperature.inputImage = result
        temperature.neutral = CIVector(x: 6_500, y: 0)
        temperature.targetNeutral = CIVector(x: adjustment.temperature, y: adjustment.tint)
        result = temperature.outputImage ?? result

        let controls = CIFilter.colorControls()
        controls.inputImage = result
        controls.contrast = Float(1 + adjustment.contrast / 100)
        controls.saturation = Float(1 + adjustment.saturation / 100)
        return controls.outputImage ?? result
    }

    private func thumbnailCGImage(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func linearChannel(_ value: UInt8) -> Double {
        let channel = Double(value) / 255
        if channel <= 0.04045 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }

    private func trimmedArithmeticMean(
        counts: [Int],
        luminanceSums: [Double],
        sampleCount: Int,
        trimFraction: Double
    ) -> Double {
        guard sampleCount > 0 else { return 0.000_001 }
        let trim = Int(Double(sampleCount) * min(max(trimFraction, 0), 0.45))
        let keepStart = trim
        let keepEnd = sampleCount - trim
        var cursor = 0
        var keptCount = 0
        var keptLuminanceSum = 0.0

        for index in counts.indices where counts[index] > 0 {
            let binStart = cursor
            let binEnd = cursor + counts[index]
            let overlapStart = max(binStart, keepStart)
            let overlapEnd = min(binEnd, keepEnd)
            if overlapStart < overlapEnd {
                let fraction = Double(overlapEnd - overlapStart) / Double(counts[index])
                keptCount += overlapEnd - overlapStart
                keptLuminanceSum += luminanceSums[index] * fraction
            }
            cursor = binEnd
        }
        guard keptCount > 0 else { return 0.000_001 }
        return max(keptLuminanceSum / Double(keptCount), 0.000_001)
    }
}
