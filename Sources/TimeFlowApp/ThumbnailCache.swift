import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let directory: URL
    private let maxBytes: Int
    private var writesSinceTrim = 0

    init(cacheDirectory: URL? = nil, maxBytes: Int = 512 * 1_024 * 1_024) {
        self.directory = cacheDirectory ?? Self.defaultDirectory()
        self.maxBytes = max(maxBytes, 1_024 * 1_024)
    }

    func image(for sourceURL: URL, maxPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = try cacheURL(for: sourceURL, maxPixelSize: maxPixelSize)
        if let cached = decode(destination) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )
            return cached
        }

        try Task.checkCancellation()
        let image = try autoreleasepool {
            try ImagePipeline.shared.decodedThumbnail(
                url: sourceURL,
                maxPixelSize: maxPixelSize
            )
        }
        try Task.checkCancellation()
        try writeJPEG(image, to: destination)
        writesSinceTrim += 1
        if writesSinceTrim >= 32 {
            writesSinceTrim = 0
            trimIfNeeded()
        }
        return image
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func cacheFileCount() throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jpg" }.count
    }

    private func cacheURL(for sourceURL: URL, maxPixelSize: Int) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let modificationBits = (modificationDate?.timeIntervalSince1970 ?? 0).bitPattern
        let identity = [
            sourceURL.standardizedFileURL.path,
            String(fileSize),
            String(modificationBits),
            String(maxPixelSize)
        ].joined(separator: "|")
        return directory.appendingPathComponent(Self.stableHash(identity) + ".jpg")
    }

    private func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeJPEG(_ image: CGImage, to destination: URL) throws {
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard let writer = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TimeFlowError.previewRenderingFailed
        }
        CGImageDestinationAddImage(
            writer,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        )
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: temporary)
            throw TimeFlowError.previewRenderingFailed
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func trimIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "jpg",
                  let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        let target = Int(Double(maxBytes) * 0.9)
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > target {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil {
                total -= entry.1
            }
        }
    }

    private static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TimeFlow Studio", isDirectory: true)
            .appendingPathComponent("Thumbnail Cache", isDirectory: true)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
