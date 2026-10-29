import Foundation
import ImageIO

enum ImageSequenceLoader {
    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf"
    ]

    static func load(from directory: URL) throws -> [FrameRecord] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return try load(from: urls)
    }

    static func load(from selectedURLs: [URL]) throws -> [FrameRecord] {
        let urls = selectedURLs
            .filter(isSupportedImage)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !urls.isEmpty else { throw TimeFlowError.noImagesFound }
        return urls.map {
            FrameRecord(
                url: $0,
                metadata: metadata(for: $0),
                sourceAdjustment: XMPDocument.adjustment(for: $0)
            )
        }
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func metadata(for url: URL) -> CaptureMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return CaptureMetadata()
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateText = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)

        return CaptureMetadata(
            pixelWidth: number(properties[kCGImagePropertyPixelWidth])?.intValue,
            pixelHeight: number(properties[kCGImagePropertyPixelHeight])?.intValue,
            exposureTime: number(exif?[kCGImagePropertyExifExposureTime])?.doubleValue,
            aperture: number(exif?[kCGImagePropertyExifFNumber])?.doubleValue,
            iso: isoValue(exif?[kCGImagePropertyExifISOSpeedRatings]),
            captureDate: parseEXIFDate(dateText)
        )
    }

    private static func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private static func isoValue(_ value: Any?) -> Double? {
        if let numbers = value as? [NSNumber], let first = numbers.first {
            return first.doubleValue
        }
        return (value as? NSNumber)?.doubleValue
    }

    private static func parseEXIFDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
