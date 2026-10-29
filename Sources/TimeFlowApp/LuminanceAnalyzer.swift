import Foundation

struct LuminanceMeasurement: Sendable, Equatable {
    let index: Int
    let value: Double
}

enum LuminanceAnalyzer {
    typealias ProgressHandler = @Sendable ([LuminanceMeasurement], Int, Int) async -> Void
    typealias Measure = @Sendable (URL) async throws -> Double

    static func analyze(
        urls: [URL],
        maxConcurrent: Int = 4,
        batchSize: Int = 16,
        progress: ProgressHandler? = nil
    ) async throws -> [Double?] {
        try await analyze(
            urls: urls,
            maxConcurrent: maxConcurrent,
            batchSize: batchSize,
            progress: progress
        ) { url in
            try Task.checkCancellation()
            return try autoreleasepool {
                try ImagePipeline.shared.luminance(of: url)
            }
        }
    }

    static func analyze(
        urls: [URL],
        maxConcurrent: Int,
        batchSize: Int,
        progress: ProgressHandler?,
        measure: @escaping Measure
    ) async throws -> [Double?] {
        guard !urls.isEmpty else { return [] }
        try Task.checkCancellation()

        let concurrency = min(max(maxConcurrent, 1), urls.count)
        let progressBatchSize = max(batchSize, 1)
        var results = [Double?](repeating: nil, count: urls.count)

        return try await withThrowingTaskGroup(of: LuminanceMeasurement.self) { group in
            var nextIndex = 0
            var completed = 0
            var pendingProgress: [LuminanceMeasurement] = []

            func addTask(at index: Int) {
                let url = urls[index]
                group.addTask {
                    try Task.checkCancellation()
                    let value = try await measure(url)
                    try Task.checkCancellation()
                    return LuminanceMeasurement(index: index, value: value)
                }
            }

            for _ in 0..<concurrency {
                addTask(at: nextIndex)
                nextIndex += 1
            }

            while let measurement = try await group.next() {
                try Task.checkCancellation()
                results[measurement.index] = measurement.value
                completed += 1
                pendingProgress.append(measurement)

                if nextIndex < urls.count {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }

                if pendingProgress.count >= progressBatchSize || completed == urls.count {
                    await progress?(pendingProgress, completed, urls.count)
                    pendingProgress.removeAll(keepingCapacity: true)
                }
            }
            return results
        }
    }
}
