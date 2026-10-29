import Foundation

enum AdjustmentEngine {
    static func adjustment(at index: Int, keyframes: [AdjustmentKeyframe]) -> Adjustment {
        let ordered = keyframes.sorted { $0.frameIndex < $1.frameIndex }
        guard let first = ordered.first else { return .neutral }
        if index <= first.frameIndex { return first.adjustment }
        guard let last = ordered.last, index < last.frameIndex else {
            return ordered.last?.adjustment ?? .neutral
        }

        guard let rightIndex = ordered.firstIndex(where: { $0.frameIndex >= index }), rightIndex > 0 else {
            return first.adjustment
        }
        let left = ordered[rightIndex - 1]
        let right = ordered[rightIndex]
        let span = max(right.frameIndex - left.frameIndex, 1)
        let linear = Double(index - left.frameIndex) / Double(span)
        let smooth = linear * linear * (3 - 2 * linear)
        return Adjustment.interpolate(from: left.adjustment, to: right.adjustment, amount: smooth)
    }

    static func deflickerCorrections(
        luminances: [Double?],
        strength: Double,
        window: Int
    ) -> [Double] {
        let logLuminances = luminances.map { value -> Double? in
            guard let value, value.isFinite, value > 0 else { return nil }
            return log2(value)
        }
        guard logLuminances.contains(where: { $0 != nil }) else {
            return Array(repeating: 0, count: luminances.count)
        }

        // A rolling median in log2 luminance space estimates the intended local
        // brightness trend while rejecting isolated exposure jumps. Edge samples
        // are padded, keeping a smooth sunrise/sunset ramp unchanged instead of
        // pulling the whole sequence toward one global brightness target.
        let radius = max(0, (max(window, 1) - 1) / 2)
        let appliedStrength = min(max(strength, 0), 1)
        return logLuminances.indices.map { index -> Double in
            guard let measured = logLuminances[index] else { return 0 }
            guard radius > 0 else { return 0 }

            var neighborhood: [Double] = []
            neighborhood.reserveCapacity(radius * 2 + 1)
            for offset in -radius...radius {
                let paddedIndex = min(max(index + offset, 0), logLuminances.count - 1)
                if let value = logLuminances[paddedIndex] {
                    neighborhood.append(value)
                }
            }
            guard !neighborhood.isEmpty else { return 0 }
            let desiredTrend = median(neighborhood)
            return min(max(desiredTrend - measured, -4), 4) * appliedStrength
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
