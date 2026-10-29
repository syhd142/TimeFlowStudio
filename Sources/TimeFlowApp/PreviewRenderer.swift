import CoreGraphics
import Foundation

actor PreviewRenderer {
    static let shared = PreviewRenderer()

    func render(url: URL, maxPixelSize: Int, adjustment: Adjustment) async throws -> CGImage {
        try Task.checkCancellation()
        let thumbnail = try await ThumbnailCache.shared.image(
            for: url,
            maxPixelSize: maxPixelSize
        )
        try Task.checkCancellation()
        return try autoreleasepool {
            try ImagePipeline.shared.previewCGImage(
                thumbnail: thumbnail,
                adjustment: adjustment
            )
        }
    }
}
