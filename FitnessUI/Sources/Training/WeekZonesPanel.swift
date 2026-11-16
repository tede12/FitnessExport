import FitnessSyncKit
import SwiftUI

struct WeekZonesPanel: View {
    let week: WeekZones

    var body: some View {
        SectionCard(title: AppLanguage.text("Settimana di corsa"), subtitle: subtitle) {
            VStack(alignment: .leading, spacing: Brand.Spacing.l) {
                ZoneBar(week: week)
                ZoneLegend(week: week)
                HStack(spacing: Brand.Spacing.m) {
                    MissingTile(
                        label: AppLanguage.text("Facile · Z1–Z2"),
                        range: AppLanguage.format("sotto %@ bpm", week.zoneFloors[1]),
                        missing: week.missingEasy,
                        isQuality: false
                    )
                    MissingTile(
                        label: AppLanguage.text("Qualità · Z3+"),
                        range: AppLanguage.format("da %@ bpm", week.zoneFloors[1]),
                        missing: week.missingQuality,
                        isQuality: true
                    )
                }
                if !week.forecast.isEmpty {
                    ForecastList(week: week)
                }
            }
        }
    }

    private var subtitle: String {
        let origin =
            week.target.source == "athlete"
            ? AppLanguage.text("obiettivo tuo") : AppLanguage.text("obiettivo: ultime 4 settimane +10%")
        return String(
            format: AppLanguage.text("%.1f di %.0f km · %@ · %.0f%% facile"),
            week.doneTotal, week.target.kilometres, origin, week.target.easyShare * 100
        )
    }

    static let zoneColors: [Color] = [
        Brand.ink.opacity(0.55), Brand.good, Brand.warning, Brand.signal, Brand.bad,
    ]

    static var weekday: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "EEE d"
        return formatter
    }
}

private struct ZoneBar: View {
    let week: WeekZones

    private var scale: Double {
        max(week.target.kilometres, week.doneTotal + week.expected.reduce(0, +), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.inkWash.opacity(0.6))
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { zone in
                        segment(week.done[zone], zone: zone, width: width, opacity: 1)
                    }
                    if week.unzoned > 0 {
                        Rectangle().fill(Color.secondary.opacity(0.5))
                            .frame(width: width * week.unzoned / scale)
                    }
                    ForEach(0..<5, id: \.self) { zone in
                        segment(week.expected[zone], zone: zone, width: width, opacity: 0.3)
                    }
                }
                .clipShape(Capsule())
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .offset(x: width * week.target.kilometres / scale - 1)
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(
            String(
                format: AppLanguage.text("%.1f km fatti, circa %.0f previsti, obiettivo %.0f"),
                week.doneTotal, week.expected.reduce(0, +), week.target.kilometres
            )
        )
    }

    @ViewBuilder
    private func segment(_ km: Double, zone: Int, width: CGFloat, opacity: Double) -> some View {
        if km > 0.05 {
            Rectangle()
                .fill(WeekZonesPanel.zoneColors[zone].opacity(opacity))
                .frame(width: width * km / scale)
        }
    }
}

private struct ZoneLegend: View {
    let week: WeekZones

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { zone in
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Circle().fill(WeekZonesPanel.zoneColors[zone]).frame(width: 7, height: 7)
                        Text("Z\(zone + 1)").font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.1f", locale: AppLanguage.locale, week.done[zone]))
                        .font(.footnote.monospacedDigit().weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (0..<5).map { String(format: "Z%d %.1f km", locale: AppLanguage.locale, $0 + 1, week.done[$0]) }
                .joined(separator: ", ")
        )
    }
}

private struct MissingTile: View {
    let label: String
    let range: String
    let missing: Double
    let isQuality: Bool

    var body: some View {
        StatusTile(label: label, value: value, note: note, tone: tone)
    }

    private var value: String {
        missing >= 0.5 ? String(format: "%.0f km", locale: AppLanguage.locale, missing) : AppLanguage.text("fatto")
    }

    private var note: String {
        if missing >= 0.5 { return AppLanguage.format("mancano · %@", range) }
        if missing <= -0.5 {
            return String(format: AppLanguage.text("%.0f km oltre · %@"), locale: AppLanguage.locale, -missing, range)
        }
        return range
    }

    private var tone: StatusTile.Tone {
        if isQuality { return missing <= -2 ? .bad : .neutral }
        return missing < 0.5 ? .good : .neutral
    }
}

private struct ForecastList: View {
    let week: WeekZones

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            Text(AppLanguage.text("PROBABILE, DALLE SETTIMANE SCORSE"))
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            ForEach(week.forecast) { day in
                ForecastRow(day: day, easyFloor: week.zoneFloors[1])
            }
            if !week.freeDays.isEmpty, week.missingEasy >= 0.5 {
                Text(freeDaysAdvice)
                    .font(.callout)
                    .padding(.top, Brand.Spacing.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var freeDaysAdvice: String {
        let days = week.freeDays.compactMap { $0.date.map(WeekZonesPanel.weekday.string) }
        let perDay = week.missingEasy / Double(max(days.count, 1))
        return String(
            format: AppLanguage.text(
                "Metti i %.0f km facili in %@ (~%.0f km l'uno, sotto %d bpm): sono i giorni senza un'abitudine."),
            week.missingEasy, days.joined(separator: ", "), perDay, week.zoneFloors[1]
        )
    }
}

private struct ForecastRow: View {
    let day: DayForecast
    let easyFloor: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Brand.Spacing.m) {
            Text(day.date.map(WeekZonesPanel.weekday.string) ?? day.day)
                .font(.subheadline.weight(.semibold))
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.monospacedDigit())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            MiniZoneBar(share: day.zoneShare)
                .frame(width: 60, height: 6)
                .opacity(day.probability >= 0.5 ? 1 : 0.4)
        }
    }

    private var headline: String {
        guard day.weeksWithRun > 0 else { return AppLanguage.text("di solito niente corsa") }
        return String(
            format: AppLanguage.text("%.0f%% · ~%.0f km"), day.probability * 100, day.kilometres
        )
    }

    private var detail: String {
        var parts = [
            AppLanguage.format(
                "%@ su %@ settimane", day.weeksWithRun, day.weeksObserved)
        ]
        if day.weeksWithRun > 0 {
            let easy = ZoneBand.easy.sum(day.zoneShare)
            parts.append(String(format: AppLanguage.text("%.0f%% facile"), locale: AppLanguage.locale, easy * 100))
        }
        if let name = day.usualPlanName { parts.append(name) }
        return parts.joined(separator: " · ")
    }
}

private struct MiniZoneBar: View {
    let share: [Double]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { zone in
                    Rectangle()
                        .fill(WeekZonesPanel.zoneColors[zone])
                        .frame(width: proxy.size.width * (share.indices.contains(zone) ? share[zone] : 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.inkWash.opacity(0.6))
            .clipShape(Capsule())
        }
    }
}
