import Foundation

struct DistanceSampleSegment: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let meters: Double
}

struct TimedValueSample: Equatable, Sendable {
    let startDate: Date
    let endDate: Date
    let value: Double
}

enum SplitComputation {
    static func computeKilometerSplits(
        distanceSamples: [DistanceSampleSegment],
        heartRateSamples: [TimedValueSample],
        cadenceSamples: [TimedValueSample],
        kilometerLength: Double = 1_000
    ) -> [RunSplitMetric] {
        let orderedSamples =
            distanceSamples
            .filter { $0.meters > 0 && $0.effectiveEndDate > $0.startDate }
            .sorted { $0.startDate < $1.startDate }
        guard let firstStart = orderedSamples.first?.startDate else { return [] }

        let totalMeters = orderedSamples.reduce(0) { $0 + $1.meters }
        let fullKilometers = Int(totalMeters / kilometerLength)
        guard fullKilometers > 0 else { return [] }

        var cumulativeMeters = 0.0
        var nextKilometer = 1
        var previousSplitStart = firstStart
        var results: [RunSplitMetric] = []

        for sample in orderedSamples {
            var localStart = sample.startDate
            var remainingMeters = sample.meters

            while nextKilometer <= fullKilometers,
                cumulativeMeters + remainingMeters >= Double(nextKilometer) * kilometerLength,
                remainingMeters > 0
            {
                let targetMeters = Double(nextKilometer) * kilometerLength
                let metersToTarget = targetMeters - cumulativeMeters
                let progress = metersToTarget / remainingMeters
                let crossingTime = localStart.addingTimeInterval(
                    sample.effectiveEndDate.timeIntervalSince(localStart) * progress)
                let interval = DateInterval(start: previousSplitStart, end: crossingTime)
                let duration = interval.duration

                results.append(
                    RunSplitMetric(
                        kilometer: nextKilometer,
                        duration: duration,
                        paceSecondsPerKilometer: duration / (kilometerLength / 1_000),
                        averageHeartRate: weightedAverage(samples: heartRateSamples, in: interval),
                        averageCadence: weightedAverage(samples: cadenceSamples, in: interval)
                    )
                )

                previousSplitStart = crossingTime
                cumulativeMeters += metersToTarget
                remainingMeters -= metersToTarget
                localStart = crossingTime
                nextKilometer += 1
            }

            cumulativeMeters += remainingMeters
        }

        return results
    }

    static func computeLapMetrics(
        laps: [WorkoutLap],
        workoutStart: Date,
        distanceSamples: [DistanceSampleSegment],
        heartRateSamples: [TimedValueSample],
        cadenceSamples: [TimedValueSample]
    ) -> [LapMetric] {
        laps.enumerated().map { index, lap in
            let meters = distance(samples: distanceSamples, in: lap.interval)
            return LapMetric(
                index: index + 1,
                intensity: lap.intensity,
                name: lap.name,
                startOffset: lap.interval.start.timeIntervalSince(workoutStart),
                duration: lap.interval.duration,
                distanceInMeters: meters > 0 ? meters : nil,
                averageHeartRate: weightedAverage(samples: heartRateSamples, in: lap.interval),
                averageCadence: weightedAverage(samples: cadenceSamples, in: lap.interval)
            )
        }
    }

    static func distance(samples: [DistanceSampleSegment], in interval: DateInterval) -> Double {
        samples.reduce(0) { total, sample in
            let sampleInterval = DateInterval(start: sample.startDate, end: sample.effectiveEndDate)
            guard sampleInterval.duration > 0, let overlap = sampleInterval.overlap(with: interval) else {
                return total
            }
            return total + sample.meters * (overlap.duration / sampleInterval.duration)
        }
    }

    static func weightedAverage(samples: [TimedValueSample], in interval: DateInterval) -> Double? {
        var weightedSum = 0.0
        var totalWeight = 0.0

        for sample in samples {
            let sampleInterval = DateInterval(start: sample.startDate, end: sample.effectiveEndDate)
            guard let overlap = sampleInterval.overlap(with: interval) else { continue }
            weightedSum += sample.value * overlap.duration
            totalWeight += overlap.duration
        }

        guard totalWeight > 0 else { return nil }
        return weightedSum / totalWeight
    }
}

extension DistanceSampleSegment {
    fileprivate var effectiveEndDate: Date {
        endDate > startDate ? endDate : startDate.addingTimeInterval(1)
    }
}

extension TimedValueSample {
    fileprivate var effectiveEndDate: Date {
        endDate > startDate ? endDate : startDate.addingTimeInterval(1)
    }
}

extension DateInterval {
    fileprivate func overlap(with other: DateInterval) -> DateInterval? {
        let lowerBound = max(start, other.start)
        let upperBound = min(end, other.end)
        guard upperBound > lowerBound else { return nil }
        return DateInterval(start: lowerBound, end: upperBound)
    }
}
