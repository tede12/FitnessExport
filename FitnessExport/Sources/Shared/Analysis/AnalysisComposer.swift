import FitnessUI
import Foundation

struct AnalysisComposer: Sendable {
    func compose(
        details: [WorkoutDetailSnapshot],
        selectedItems: [WorkoutListItem],
        periodDescription: String,
        seriesByWorkout: [UUID: WorkoutAnalysisSeries] = [:]
    ) -> String {
        guard !details.isEmpty else {
            return AppLanguage.text("Nessuna attività selezionata.")
        }

        let orderedDetails = details.sorted { lhs, rhs in
            let lhsIndex = selectedItems.firstIndex(where: { $0.id == lhs.id }) ?? 0
            let rhsIndex = selectedItems.firstIndex(where: { $0.id == rhs.id }) ?? 0
            return lhsIndex < rhsIndex
        }

        var lines: [String] = [AppLanguage.text("Analisi allenamenti"), ""]

        if orderedDetails.count > 1 {
            let totalDistance = orderedDetails.compactMap(\.distanceInMeters).reduce(0, +)
            let totalDuration = orderedDetails.reduce(0) { $0 + $1.duration }
            lines.append(AppLanguage.format("Periodo: %@", periodDescription))
            lines.append(AppLanguage.format("Attività selezionate: %@", orderedDetails.count))
            lines.append(
                AppLanguage.format(
                    "Distanza totale: %@", WorkoutFormatting.distance(totalDistance) ?? "n.d."))
            lines.append(
                AppLanguage.format("Durata totale: %@", WorkoutFormatting.duration(totalDuration)))

            if let pace = WorkoutFormatting.pace(distanceInMeters: totalDistance, duration: totalDuration) {
                lines.append(AppLanguage.format("Passo medio aggregato: %@", pace))
            }

            if let averageHeartRate = weightedAverage(
                values: orderedDetails.compactMap {
                    guard let value = $0.averageHeartRate else { return nil }
                    return (value, $0.duration)
                })
            {
                lines.append(
                    AppLanguage.format(
                        "FC media aggregata: %@",
                        WorkoutFormatting.heartRate(averageHeartRate) ?? ""))
            }

            if let averageCadence = weightedAverage(
                values: orderedDetails.compactMap {
                    guard let value = $0.averageCadence else { return nil }
                    return (value, $0.duration)
                })
            {
                lines.append(
                    AppLanguage.format(
                        "Cadenza media aggregata: %@",
                        WorkoutFormatting.cadence(averageCadence) ?? ""))
            }

            lines.append("")
        }

        for (index, detail) in orderedDetails.enumerated() {
            let series = seriesByWorkout[detail.id]
            let title = [detail.workoutName, detail.activityType.title].compactMap { $0 }.joined(separator: " · ")
            lines.append("\(title) · \(WorkoutFormatting.workoutDate(detail.startDate))")

            if let distance = WorkoutFormatting.distance(detail.distanceInMeters) {
                lines.append(AppLanguage.format("Distanza: %@", distance))
            }
            lines.append(
                AppLanguage.format("Durata: %@", WorkoutFormatting.duration(detail.duration)))

            if let pace = WorkoutFormatting.pace(distanceInMeters: detail.distanceInMeters, duration: detail.duration) {
                lines.append(AppLanguage.format("Passo medio: %@", pace))
            }

            if let averageHeartRate = detail.averageHeartRate {
                if let maxHeartRate = detail.maxHeartRate {
                    lines.append(
                        AppLanguage.format(
                            "FC media/max: %@ / %@",
                            WorkoutFormatting.heartRate(averageHeartRate) ?? "",
                            WorkoutFormatting.heartRate(maxHeartRate) ?? ""))
                } else {
                    lines.append(
                        AppLanguage.format(
                            "FC media: %@", WorkoutFormatting.heartRate(averageHeartRate) ?? ""))
                }
            }

            if let averageCadence = detail.averageCadence {
                lines.append(
                    AppLanguage.format(
                        "Cadenza media: %@", WorkoutFormatting.cadence(averageCadence) ?? ""))
            }

            if let series, !series.power.isEmpty {
                let values = series.power.map(\.value)
                lines.append(
                    AppLanguage.format(
                        "Potenza media/max: %@ / %@ W",
                        Int((values.reduce(0, +) / Double(values.count)).rounded()),
                        Int((values.max() ?? 0).rounded())))
            }

            if let energy = WorkoutFormatting.kilocalories(detail.activeEnergyKilocalories) {
                lines.append(AppLanguage.format("Energia attiva: %@", energy))
            }

            if !detail.splits.isEmpty {
                lines.append(AppLanguage.text("Split per km"))
                lines.append(contentsOf: splitTable(detail.splits, detail: detail, powerSamples: series?.power ?? []))
            }

            if detail.hasIntervals {
                lines.append(AppLanguage.text("Intervalli"))
                lines.append(contentsOf: lapTable(detail.laps, detail: detail, powerSamples: series?.power ?? []))
            }

            if index < orderedDetails.count - 1 {
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func splitTable(_ splits: [RunSplitMetric], detail: WorkoutDetailSnapshot, powerSamples: [TimedValueSample])
        -> [String]
    {
        let hasHeartRate = splits.contains { $0.averageHeartRate != nil }
        let hasCadence = splits.contains { $0.averageCadence != nil }
        let hasPower = !powerSamples.isEmpty

        var header = ["km", AppLanguage.text("passo")]
        if hasHeartRate { header.append(AppLanguage.text("FC media")) }
        if hasCadence { header.append(AppLanguage.text("cadenza media")) }
        if hasPower { header.append(AppLanguage.text("potenza media")) }

        var rows = [header.joined(separator: " | ")]
        var elapsed: TimeInterval = 0
        for split in splits {
            var columns = [
                "\(split.kilometer)",
                WorkoutFormatting.pace(secondsPerKilometer: split.paceSecondsPerKilometer) ?? "-",
            ]
            if hasHeartRate { columns.append(WorkoutFormatting.heartRate(split.averageHeartRate) ?? "-") }
            if hasCadence { columns.append(WorkoutFormatting.cadence(split.averageCadence) ?? "-") }
            if hasPower {
                let interval = DateInterval(
                    start: detail.startDate.addingTimeInterval(elapsed), duration: split.duration)
                columns.append(
                    SplitComputation.weightedAverage(samples: powerSamples, in: interval).map {
                        "\(Int($0.rounded())) W"
                    } ?? "-")
            }
            rows.append(columns.joined(separator: " | "))
            elapsed += split.duration
        }
        return rows
    }

    private func lapTable(_ laps: [LapMetric], detail: WorkoutDetailSnapshot, powerSamples: [TimedValueSample])
        -> [String]
    {
        let hasPower = !powerSamples.isEmpty
        var header = [
            AppLanguage.text("fase"), AppLanguage.text("tempo"), AppLanguage.text("distanza"),
            AppLanguage.text("passo"), AppLanguage.text("FC"), AppLanguage.text("cadenza"),
        ]
        if hasPower { header.append(AppLanguage.text("potenza")) }
        return [header.joined(separator: " | ")]
            + laps.map { lap in
                let interval = DateInterval(
                    start: detail.startDate.addingTimeInterval(lap.startOffset), duration: lap.duration)
                var columns = [
                    "\(lap.index). \(lap.name ?? Self.intensityTitle(lap.intensity))",
                    WorkoutFormatting.duration(lap.duration),
                    lap.distanceInMeters.map(WorkoutFormatting.lapDistance) ?? "-",
                    WorkoutFormatting.pace(secondsPerKilometer: lap.paceSecondsPerKilometer) ?? "-",
                    WorkoutFormatting.heartRate(lap.averageHeartRate) ?? "-",
                    WorkoutFormatting.cadence(lap.averageCadence) ?? "-",
                ]
                if hasPower {
                    columns.append(
                        SplitComputation.weightedAverage(samples: powerSamples, in: interval).map {
                            "\(Int($0.rounded())) W"
                        } ?? "-")
                }
                return columns.joined(separator: " | ")
            }
    }

    private static func intensityTitle(_ intensity: LapIntensity) -> String {
        switch intensity {
        case .active: AppLanguage.text("Lavoro")
        case .recovery: AppLanguage.text("Recupero")
        case .rest: AppLanguage.text("Pausa")
        case .warmup: AppLanguage.text("Riscaldamento")
        case .cooldown: AppLanguage.text("Defaticamento")
        }
    }

    private func weightedAverage(values: [(Double, TimeInterval)]) -> Double? {
        guard !values.isEmpty else { return nil }
        let totalWeight = values.reduce(0) { $0 + max($1.1, 1) }
        let weightedSum = values.reduce(0) { $0 + ($1.0 * max($1.1, 1)) }
        return weightedSum / totalWeight
    }
}
