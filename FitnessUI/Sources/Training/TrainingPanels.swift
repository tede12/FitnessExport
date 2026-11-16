import FitnessSyncKit
import SwiftUI

struct PlanPanel: View {
    let plan: [PlanItem]
    let sessions: [SessionSummary]
    let onToggle: ((PlanItem) -> Void)?
    let onSendToWatch: ((PlanItem) async -> Void)?
    let isSending: Bool

    var body: some View {
        SectionCard(title: AppLanguage.text("Questa settimana"), subtitle: subtitle) {
            if plan.isEmpty {
                Text(AppLanguage.text("Nessuna seduta pianificata."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(plan.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.vertical, Brand.Spacing.s)
                        }
                        PlanItemRow(
                            item: item,
                            recorded: sessions.filter { $0.day == item.day },
                            onToggle: onToggle.map { action in { action(item) } },
                            onSendToWatch: onSendToWatch.map { action in { await action(item) } },
                            isSending: isSending
                        )
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let done = plan.filter(\.done).count
        guard !plan.isEmpty else { return AppLanguage.text("niente in programma") }
        return AppLanguage.format("%@ di %@ fatte", done, plan.count)
    }
}

struct PlanItemRow: View {
    let item: PlanItem
    let recorded: [SessionSummary]
    let onToggle: (() -> Void)?
    let onSendToWatch: (() async -> Void)?
    let isSending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Spacing.m) {
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(item.done ? Brand.good : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    item.done ? AppLanguage.text("Segna come da fare") : AppLanguage.text("Segna come fatta"))
            } else {
                IconTile(systemName: icon, size: 30, tint: tint, wash: wash)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(weekday)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(isToday ? Brand.signal : Brand.inkWash, in: Capsule())
                        .foregroundStyle(isToday ? .white : Brand.ink)
                    if item.slot == "coach" {
                        Text("coach")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Brand.ink, in: Capsule())
                            .foregroundStyle(Brand.cardSurface)
                    }
                    if let rpe = item.rpe {
                        Text("RPE \(rpe)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Brand.goodWash, in: Capsule())
                            .foregroundStyle(Brand.good)
                    }
                }
                Text(item.title)
                    .font(.headline)
                if let target = item.target, target != "—" {
                    Text(target)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Brand.ink)
                }
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !recorded.isEmpty {
                    Label {
                        Text(recorded.map(describe).joined(separator: " · "))
                            .font(.caption)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                    }
                    .foregroundStyle(Brand.good)
                }
                if let overshoot {
                    Label {
                        Text(overshoot)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                    }
                    .foregroundStyle(Brand.signal)
                }
                if let onSendToWatch {
                    Button {
                        Task { await onSendToWatch() }
                    } label: {
                        Label(AppLanguage.text("Manda al Watch"), systemImage: "applewatch")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSending)
                    .padding(.top, 2)
                }
            }
            .opacity(item.done ? 0.6 : 1)
            Spacer(minLength: 0)
        }
    }

    private var isToday: Bool {
        item.day == PlanItem.dayFormatter.string(from: Date())
    }

    private var icon: String {
        switch item.slot {
        case "coach": return "figure.track.and.field"
        case "strength": return "figure.strengthtraining.traditional"
        case "long": return "figure.run"
        case "easy": return "figure.walk"
        default: return "moon.zzz"
        }
    }

    private var tint: Color { item.done ? Brand.good : Brand.ink }
    private var wash: Color { item.done ? Brand.goodWash : Brand.inkWash }

    private var weekday: String {
        guard let date = item.date else { return item.day }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date).lowercased()
    }

    private func describe(_ session: SessionSummary) -> String {
        var parts = ["\(session.activity) \(Int(session.minutes))′"]
        if let km = session.kilometres, km > 0 {
            parts.append(String(format: "%.1f km", locale: AppLanguage.locale, km))
        }
        if let pace = session.pace { parts.append("\(pace)/km") }
        if let heartRate = session.heartRate { parts.append("FC \(Int(heartRate))") }
        return parts.joined(separator: " · ")
    }

    private var overshoot: String? {
        guard let range = item.heartRateRange else { return nil }
        let over = recorded.filter {
            $0.activity == "running" && ($0.heartRate ?? 0) > range.upperBound
        }
        guard let worst = over.compactMap(\.heartRate).max() else { return nil }
        return AppLanguage.format(
            "FC media %@, sopra il tetto di %@: non era la seduta prescritta", Int(worst),
            Int(range.upperBound))
    }
}

struct ChartsPanel: View {
    let series: TrendSeries

    var body: some View {
        VStack(spacing: Brand.Spacing.l) {
            if !series.volume.isEmpty {
                ChartCard(
                    title: AppLanguage.text("Volume di corsa"),
                    subtitle: AppLanguage.text("km a settimana · il punto segna una settimana con forza")
                ) {
                    VolumeTrendChart(weeks: series.volume)
                        .frame(height: 170)
                }
            }

            let hrv = series.hrvPoints()
            if !hrv.isEmpty {
                ChartCard(
                    title: "HRV",
                    subtitle: AppLanguage.text(
                        "punti: la misura del giorno · linea spessa: media di 7 giorni · fascia: il tuo normale")
                ) {
                    VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                        LineTrendChart(
                            series: [
                                .init(
                                    name: "HRV", colour: Brand.good, points: hrv,
                                    showsBaseline: true, showsNormalBand: true
                                )
                            ],
                            suffix: "ms"
                        )
                        .frame(height: 170)
                        TrendReading(points: hrv, unit: "ms", higherIsBetter: true)
                    }
                }
            }

            let resting = series.restingPoints()
            if !resting.isEmpty {
                ChartCard(
                    title: AppLanguage.text("FC a riposo"),
                    subtitle: AppLanguage.text(
                        "punti: la misura del giorno · linea spessa: media di 7 giorni · fascia: il tuo normale")
                ) {
                    VStack(alignment: .leading, spacing: Brand.Spacing.s) {
                        LineTrendChart(
                            series: [
                                .init(
                                    name: AppLanguage.text("FC a riposo"), colour: Brand.signal,
                                    points: resting, showsBaseline: true, showsNormalBand: true
                                )
                            ],
                            suffix: "bpm"
                        )
                        .frame(height: 170)
                        TrendReading(points: resting, unit: "bpm", higherIsBetter: false)
                    }
                }
            }

            let sleep = series.sleepPoints()
            if !sleep.isEmpty {
                ChartCard(
                    title: AppLanguage.text("Sonno"),
                    subtitle: AppLanguage.text("in corallo le notti sotto le 6 ore")
                ) {
                    ThresholdBarChart(
                        points: sleep, threshold: 7, thresholdLabel: "7 h", suffix: "h"
                    )
                    .frame(height: 170)
                }
            }

            let mass = series.massPoints()
            let lean = series.leanPoints()
            if !mass.isEmpty {
                ChartCard(
                    title: AppLanguage.text("Peso e massa magra"),
                    subtitle: AppLanguage.text("muscolo su, grasso fermo: è così che si vede")
                ) {
                    VStack(spacing: Brand.Spacing.s) {
                        LineTrendChart(
                            series: [
                                .init(
                                    name: AppLanguage.text("Peso"), colour: Brand.ink, points: mass,
                                    showsBaseline: false),
                                .init(
                                    name: AppLanguage.text("Massa magra"), colour: Brand.good, points: lean,
                                    showsBaseline: false),
                            ],
                            suffix: "kg", decimals: 1
                        )
                        .frame(height: 170)
                        ChartLegend(items: [
                            .init(label: "peso", swatch: .line(Brand.ink)),
                            .init(label: AppLanguage.text("massa magra"), swatch: .line(Brand.good)),
                        ])
                    }
                }
            }

            let vo2 = series.vo2Points()
            if !vo2.isEmpty {
                ChartCard(
                    title: "VO2max",
                    subtitle: AppLanguage.text("capacità aerobica stimata dal Watch, per mese")
                ) {
                    LineTrendChart(
                        series: [
                            .init(name: "VO2max", colour: Brand.ink, points: vo2, showsBaseline: false)
                        ],
                        suffix: "", decimals: 1
                    )
                    .frame(height: 170)
                }
            }

            let efficiency = series.efficiencyPoints()
            if !efficiency.isEmpty {
                ChartCard(
                    title: AppLanguage.text("Efficienza"),
                    subtitle: AppLanguage.text("velocità ÷ frequenza cardiaca · sale quando migliori")
                ) {
                    LineTrendChart(
                        series: [
                            .init(
                                name: AppLanguage.text("Efficienza"), colour: Brand.good, points: efficiency,
                                showsBaseline: false)
                        ],
                        decimals: 1
                    )
                    .frame(height: 170)
                }
            }

            let contact = series.groundContactPoints()
            if !contact.isEmpty {
                ChartCard(
                    title: AppLanguage.text("Contatto al suolo"),
                    subtitle: AppLanguage.text("millisecondi · scende quando la spinta migliora")
                ) {
                    LineTrendChart(
                        series: [
                            .init(
                                name: AppLanguage.text("Contatto"), colour: Brand.signal, points: contact,
                                showsBaseline: false)
                        ],
                        suffix: "ms"
                    )
                    .frame(height: 170)
                }
            }

            let cadence = series.cadencePoints()
            if !cadence.isEmpty {
                ChartCard(title: AppLanguage.text("Cadenza"), subtitle: AppLanguage.text("passi al minuto")) {
                    LineTrendChart(
                        series: [
                            .init(
                                name: AppLanguage.text("Cadenza"), colour: Brand.ink, points: cadence,
                                showsBaseline: false)
                        ],
                        suffix: "spm"
                    )
                    .frame(height: 170)
                }
            }
        }
    }
}

struct TrendReading: View {
    let points: [SeriesPoint]
    let unit: String
    let higherIsBetter: Bool

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var text: String? {
        guard let range = NormalRange.of(points.map(\.value)), let last = points.last else {
            return nil
        }
        let week = points.suffix(7).map(\.value)
        let mean = week.reduce(0, +) / Double(week.count)
        let band = String(format: "%.0f–%.0f %@", locale: AppLanguage.locale, range.lowerBound, range.upperBound, unit)

        func place(_ value: Double) -> String {
            if range.contains(value) { return "dentro" }
            let high = value > range.upperBound
            return (high == higherIsBetter)
                ? AppLanguage.text("sopra, in meglio,") : AppLanguage.text("fuori, in peggio,")
        }

        let today = String(
            format: AppLanguage.text("Ultima misura %.0f %@: %@ la tua fascia (%@)."), locale: AppLanguage.locale,
            last.value, unit, place(last.value), band)
        let trend: String
        if range.contains(mean) {
            trend = String(
                format: AppLanguage.text("La media di 7 giorni (%.0f) è nella norma: niente da cambiare."),
                locale: AppLanguage.locale, mean)
        } else if (mean > range.upperBound) == higherIsBetter {
            trend = String(
                format: AppLanguage.text(
                    "La media di 7 giorni (%.0f) è oltre la norma in meglio: stai assorbendo bene il carico."),
                locale: AppLanguage.locale, mean)
        } else {
            trend = String(
                format: AppLanguage.text(
                    "La media di 7 giorni (%.0f) è fuori norma in peggio: è una tendenza, non un giorno. Togli intensità finché non rientra."
                ), locale: AppLanguage.locale, mean)
        }
        return today + " " + trend
    }
}

struct SyncStatusBar: View {
    let generatedAt: Date
    let pendingMarks: Int
    let isSyncing: Bool
    let error: String?
    let onRefresh: (() async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            HStack(spacing: Brand.Spacing.s) {
                if isSyncing {
                    ProgressView().controlSize(.small)
                    Text(AppLanguage.text("Sincronizzazione col Mac…"))
                } else {
                    Image(systemName: error == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(error == nil ? Brand.good : Brand.signal)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(
                            AppLanguage.format(
                                "Dati del Mac %@",
                                String(
                                    describing: generatedAt.formatted(
                                        Date.RelativeFormatStyle(presentation: .named).locale(AppLanguage.locale)))))
                    }
                }
                Spacer(minLength: 0)
                if let onRefresh, !isSyncing {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Label(
                            error == nil ? AppLanguage.text("Sincronizza") : AppLanguage.text("Riprova"),
                            systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let error, !isSyncing {
                Text(AppLanguage.format("Sync non riuscito: %@", error))
                    .font(.footnote)
                    .foregroundStyle(Brand.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pendingMarks > 0 {
                Label(
                    AppLanguage.format("%@ spunte da sincronizzare", pendingMarks),
                    systemImage: "arrow.up.circle"
                )
                .font(.footnote)
                .foregroundStyle(Brand.signal)
            }
        }
        .padding(.horizontal, Brand.Spacing.m)
        .padding(.vertical, Brand.Spacing.s)
        .background(
            (error == nil ? Brand.inkWash : Brand.signalWash).opacity(0.5),
            in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
        )
        .animation(.default, value: isSyncing)
    }
}
