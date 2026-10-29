import Foundation

struct CaptureMetadata: Codable, Equatable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var exposureTime: Double?
    var aperture: Double?
    var iso: Double?
    var captureDate: Date?
}

struct FrameRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var url: URL
    var metadata: CaptureMetadata
    var luminance: Double?
    var sourceAdjustment: Adjustment?

    init(url: URL, metadata: CaptureMetadata, sourceAdjustment: Adjustment? = nil) {
        self.id = UUID()
        self.url = url
        self.metadata = metadata
        self.luminance = nil
        self.sourceAdjustment = sourceAdjustment
    }

    var displayName: String { url.lastPathComponent }
}

struct Adjustment: Codable, Equatable {
    var exposureEV: Double = 0
    var temperature: Double = 6_500
    var tint: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0

    static let neutral = Adjustment()

    static func interpolate(from lhs: Adjustment, to rhs: Adjustment, amount: Double) -> Adjustment {
        let t = min(max(amount, 0), 1)
        return Adjustment(
            exposureEV: lhs.exposureEV + (rhs.exposureEV - lhs.exposureEV) * t,
            temperature: lhs.temperature + (rhs.temperature - lhs.temperature) * t,
            tint: lhs.tint + (rhs.tint - lhs.tint) * t,
            contrast: lhs.contrast + (rhs.contrast - lhs.contrast) * t,
            saturation: lhs.saturation + (rhs.saturation - lhs.saturation) * t
        )
    }
}

struct AdjustmentKeyframe: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var frameIndex: Int
    var adjustment: Adjustment
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc
    case proRes422LT
    case proRes422

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422: return "Apple ProRes 422"
        }
    }

    var usesBitRate: Bool { self == .h264 || self == .hevc }

    func resolvedBitRateMbps(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        automatic: Bool,
        manualBitRateMbps: Int
    ) -> Int {
        guard usesBitRate else { return 0 }
        guard automatic else { return max(manualBitRateMbps, 1) }

        let referencePixelRate = Double(3_840 * 2_160 * 25)
        let pixelRate = Double(max(width, 2) * max(height, 2) * max(framesPerSecond, 1))
        let referenceBitRate = self == .h264 ? 45.0 : 28.0
        let maximumBitRate = self == .h264 ? 160 : 100
        let minimumBitRate = self == .h264 ? 5 : 4
        let scaled = Int((referenceBitRate * pixelRate / referencePixelRate).rounded())
        return min(max(scaled, minimumBitRate), maximumBitRate)
    }
}

enum VideoColorSpace: String, Codable, CaseIterable, Identifiable {
    case rec709
    case displayP3

    var id: String { rawValue }
    var displayName: String { self == .rec709 ? "Rec. 709" : "Display P3" }
}

enum VideoScalingMode: String, Codable, CaseIterable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fill: return "Fill (crop)"
        case .fit: return "Fit (black bars)"
        }
    }
}

enum VideoResolutionPreset: String, Codable, CaseIterable, Identifiable {
    case custom
    case source
    case hd
    case fullHD
    case ultraHD
    case verticalFullHD

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: return "Custom"
        case .source: return "Source size"
        case .hd: return "HD 1280 × 720"
        case .fullHD: return "Full HD 1920 × 1080"
        case .ultraHD: return "4K UHD 3840 × 2160"
        case .verticalFullHD: return "Vertical 1080 × 1920"
        }
    }

    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .custom, .source: return nil
        case .hd: return (1_280, 720)
        case .fullHD: return (1_920, 1_080)
        case .ultraHD: return (3_840, 2_160)
        case .verticalFullHD: return (1_080, 1_920)
        }
    }

    func outputDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        customWidth: Int,
        customHeight: Int
    ) -> (width: Int, height: Int) {
        switch self {
        case .custom:
            return (max(2, customWidth / 2 * 2), max(2, customHeight / 2 * 2))
        case .source:
            return (max(2, sourceWidth / 2 * 2), max(2, sourceHeight / 2 * 2))
        case .hd:
            return (1_280, 720)
        case .fullHD:
            return (1_920, 1_080)
        case .ultraHD:
            return (3_840, 2_160)
        case .verticalFullHD:
            return (1_080, 1_920)
        }
    }
}

struct StarTrailVideoSettings: Equatable {
    var resolutionPreset: VideoResolutionPreset = .ultraHD
    var framesPerSecond: Int = 25
    var codec: VideoCodec = .h264
    var automaticBitRate = true
    var bitRateMbps: Int = 45
    var colorSpace: VideoColorSpace = .rec709
    var scalingMode: VideoScalingMode = .fill
    var customWidth: Int = 1_920
    var customHeight: Int = 1_080

    func outputDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        resolutionPreset.outputDimensions(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            customWidth: customWidth,
            customHeight: customHeight
        )
    }

    func resolvedBitRateMbps(width: Int, height: Int) -> Int {
        codec.resolvedBitRateMbps(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            automatic: automaticBitRate,
            manualBitRateMbps: bitRateMbps
        )
    }
}

struct HybridVideoSettings: Equatable {
    var transitionFrames: Int = 12
    var finalHoldSeconds: Int = 3
}

struct StarTrailWorkflowSettings: Codable, Equatable {
    var startFrame: Int = 1
    var endFrame: Int = .max
    var gapFillingRadius: Int = 0
    var removeTransientStreaks = false
    var cometEnabled = false
    var cometLength = 80
    var growthVideoFPS = 25
    var growthVideoResolution = VideoResolutionPreset.ultraHD
    var growthVideoCodec = VideoCodec.h264
    var growthVideoAutomaticBitRate = true
    var growthVideoBitRateMbps = 45
    var growthVideoColorSpace = VideoColorSpace.rec709
    var growthVideoScalingMode = VideoScalingMode.fill
    var growthVideoCustomWidth = 1_920
    var growthVideoCustomHeight = 1_080
    var hybridTransitionFrames = 12
    var hybridFinalHoldSeconds = 3
}

struct ExportSettings: Codable, Equatable {
    var width: Int = 1_920
    var height: Int = 1_080
    var framesPerSecond: Int = 25
    var codec: VideoCodec = .h264
    var automaticBitRate = true
    var bitRateMbps: Int = 24
    var colorSpace: VideoColorSpace = .rec709
    var scalingMode: VideoScalingMode = .fill
    var meteorHoldSeconds: Double = 0.5
    var startFrame: Int = 1
    var endFrame: Int = .max

    init(
        width: Int = 1_920,
        height: Int = 1_080,
        framesPerSecond: Int = 25,
        codec: VideoCodec = .h264,
        automaticBitRate: Bool = true,
        bitRateMbps: Int = 24,
        colorSpace: VideoColorSpace = .rec709,
        scalingMode: VideoScalingMode = .fill,
        meteorHoldSeconds: Double = 0.5,
        startFrame: Int = 1,
        endFrame: Int = .max
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.automaticBitRate = automaticBitRate
        self.bitRateMbps = bitRateMbps
        self.colorSpace = colorSpace
        self.scalingMode = scalingMode
        self.meteorHoldSeconds = meteorHoldSeconds
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    private enum CodingKeys: String, CodingKey {
        case width, height, framesPerSecond, codec, automaticBitRate, bitRateMbps
        case colorSpace, scalingMode, meteorHoldSeconds, startFrame, endFrame
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 1_920
        height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 1_080
        framesPerSecond = try values.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 25
        codec = try values.decodeIfPresent(VideoCodec.self, forKey: .codec) ?? .h264
        automaticBitRate = try values.decodeIfPresent(Bool.self, forKey: .automaticBitRate) ?? true
        bitRateMbps = try values.decodeIfPresent(Int.self, forKey: .bitRateMbps) ?? 24
        colorSpace = try values.decodeIfPresent(VideoColorSpace.self, forKey: .colorSpace) ?? .rec709
        scalingMode = try values.decodeIfPresent(VideoScalingMode.self, forKey: .scalingMode) ?? .fill
        meteorHoldSeconds = try values.decodeIfPresent(Double.self, forKey: .meteorHoldSeconds) ?? 0.5
        startFrame = try values.decodeIfPresent(Int.self, forKey: .startFrame) ?? 1
        endFrame = try values.decodeIfPresent(Int.self, forKey: .endFrame) ?? .max
    }

    func resolvedBitRateMbps(width outputWidth: Int? = nil, height outputHeight: Int? = nil) -> Int {
        codec.resolvedBitRateMbps(
            width: outputWidth ?? width,
            height: outputHeight ?? height,
            framesPerSecond: framesPerSecond,
            automatic: automaticBitRate,
            manualBitRateMbps: bitRateMbps
        )
    }
}

struct StarTrailOptions: Equatable {
    var startIndex: Int = 0
    var endIndex: Int = .max
    var gapFillingRadius: Int = 0
    var removeTransientStreaks = false
    var transientSupportRadius: Int = 4
    var cometTailLength: Int?
    var preservedTransientFrameIndices: Set<Int> = []
    var meteorHoldSeconds: Double = 0.5
}

struct TimeFlowProject: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var name: String = "Untitled Timelapse"
    var sourceDirectory: URL?
    var frames: [FrameRecord] = []
    var keyframes: [AdjustmentKeyframe] = []
    var deflickerStrength: Double = 1
    var deflickerWindow: Int = 9
    var exportSettings = ExportSettings()
    // Optional keeps projects written by earlier TimeFlow versions decodable.
    var meteorFrameIndices: [Int]?
    var starTrailSettings: StarTrailWorkflowSettings?
}

enum TimeFlowError: LocalizedError {
    case noImagesFound
    case imageCannotBeDecoded(URL)
    case previewRenderingFailed
    case videoSetupFailed(String)
    case videoAppendFailed(Int)
    case starTrailFailed(String)
    case xmpFailed(String)
    case relinkFailed(String)

    var errorDescription: String? {
        switch self {
        case .noImagesFound:
            return "No supported images were found in the selected folder."
        case .imageCannotBeDecoded(let url):
            return "The image could not be decoded: \(url.lastPathComponent)"
        case .previewRenderingFailed:
            return "The preview could not be rendered."
        case .videoSetupFailed(let message):
            return "Video export could not start: \(message)"
        case .videoAppendFailed(let frame):
            return "Video export failed while appending frame \(frame + 1)."
        case .starTrailFailed(let message):
            return "Star trail export failed: \(message)"
        case .xmpFailed(let message):
            return "XMP operation failed: \(message)"
        case .relinkFailed(let message):
            return "Source files could not be relinked: \(message)"
        }
    }
}
