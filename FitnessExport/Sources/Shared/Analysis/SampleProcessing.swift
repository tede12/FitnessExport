import Foundation

struct SourcedSample: Equatable, Sendable {
    let source: String
    let startDate: Date
    let endDate: Date
    let value: Double
}

enum SampleSourceSelection {

    static func pickDistanceSource(_ samples: [SourcedSample], expectedTotal: Double?) -> [SourcedSample] {
        let groups = grouped(samples)
        guard !groups.isEmpty else { return [] }

        let best: [SourcedSample]?
        if let expectedTotal, expectedTotal > 0 {
            best = groups.values.min { lhs, rhs in
                abs(total(lhs) - expectedTotal) < abs(total(rhs) - expectedTotal)
            }
        } else {
            best = groups.values.max { total($0) < total($1) }
        }

        return (best ?? []).sorted { $0.startDate < $1.startDate }
    }

    static func pickRateSource(_ samples: [SourcedSample], preferredSource: String?) -> [SourcedSample] {
        let groups = grouped(samples)
        guard !groups.isEmpty else { return [] }

        if let preferredSource, let preferred = groups[preferredSource], !preferred.isEmpty {
            return preferred.sorted { $0.startDate < $1.startDate }
        }

        let best = groups.values.max { $0.count < $1.count } ?? []
        return best.sorted { $0.startDate < $1.startDate }
    }

    static func mergeHeartRateSources(_ samples: [SourcedSample], preferredSource: String?) -> [SourcedSample] {
        let groups = grouped(samples)
        let orderedSources = groups.keys.sorted { lhs, rhs in
            if lhs == preferredSource { return true }
            if rhs == preferredSource { return false }
            return (groups[lhs]?.count ?? 0) > (groups[rhs]?.count ?? 0)
        }

        var selected: [SourcedSample] = []
        let tolerance: TimeInterval = 5
        for source in orderedSources {
            let candidates = (groups[source] ?? []).sorted { $0.startDate < $1.startDate }
            var additions: [SourcedSample] = []
            var selectedIndex = 0
            for sample in candidates {
                while selectedIndex < selected.count,
                    selected[selectedIndex].startDate < sample.startDate.addingTimeInterval(-tolerance)
                {
                    selectedIndex += 1
                }
                let isCovered =
                    selectedIndex < selected.count
                    && abs(selected[selectedIndex].startDate.timeIntervalSince(sample.startDate)) <= tolerance
                if !isCovered { additions.append(sample) }
            }
            selected.append(contentsOf: additions)
            selected.sort { $0.startDate < $1.startDate }
        }
        return selected
    }

    private static func grouped(_ samples: [SourcedSample]) -> [String: [SourcedSample]] {
        Dictionary(grouping: samples, by: \.source)
    }

    private static func total(_ samples: [SourcedSample]) -> Double {
        samples.reduce(0) { $0 + $1.value }
    }
}

enum CadenceDerivation {

    static func stepsPerMinute(from stepSamples: [DistanceSampleSegment]) -> [TimedValueSample] {
        stepSamples.compactMap { sample in
            let seconds = sample.endDate.timeIntervalSince(sample.startDate)
            guard seconds >= 1, sample.meters > 0 else { return nil }
            return TimedValueSample(
                startDate: sample.startDate,
                endDate: sample.endDate,
                value: sample.meters / (seconds / 60)
            )
        }
    }
}
