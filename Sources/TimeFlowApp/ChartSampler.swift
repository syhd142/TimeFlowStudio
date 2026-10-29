import Foundation

struct ChartSample: Identifiable, Equatable {
    let index: Int
    let value: Double

    var id: Int { index }
}

enum ChartSampler {
    static func downsample(
        _ values: [Double?],
        maxPoints: Int,
        including requiredIndex: Int? = nil
    ) -> [ChartSample] {
        let limit = max(maxPoints, 2)
        let valid = values.indices.compactMap { index -> ChartSample? in
            guard let value = values[index], value.isFinite else { return nil }
            return ChartSample(index: index, value: value)
        }
        guard valid.count > limit else { return valid }

        var selected: [Int: ChartSample] = [:]
        selected[valid[0].index] = valid[0]
        selected[valid[valid.count - 1].index] = valid[valid.count - 1]
        if let requiredIndex,
           values.indices.contains(requiredIndex),
           let value = values[requiredIndex],
           value.isFinite {
            selected[requiredIndex] = ChartSample(index: requiredIndex, value: value)
        }

        let remainingBudget = max(0, limit - selected.count)
        guard remainingBudget > 0 else {
            return selected.values.sorted { $0.index < $1.index }
        }

        // Keep the local minimum and maximum from each bucket. This preserves
        // short luminance spikes while capping the number of Swift Charts marks.
        let bucketCount = max(1, (remainingBudget + 1) / 2)
        for bucket in 0..<bucketCount {
            let lower = bucket * valid.count / bucketCount
            let upper = min((bucket + 1) * valid.count / bucketCount, valid.count)
            guard lower < upper else { continue }
            let slice = valid[lower..<upper]
            guard let minimum = slice.min(by: { $0.value < $1.value }),
                  let maximum = slice.max(by: { $0.value < $1.value }) else { continue }

            for sample in [minimum, maximum].sorted(by: { $0.index < $1.index }) {
                guard selected[sample.index] == nil, selected.count < limit else { continue }
                selected[sample.index] = sample
            }
        }

        return selected.values.sorted { $0.index < $1.index }
    }
}
