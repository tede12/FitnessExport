import FitnessSyncKit
import SwiftUI

public struct TrainingDashboard: View {
    let briefing: TrainingBriefing
    let pendingMarks: Int
    let onToggle: ((PlanItem) -> Void)?
    let onSendToWatch: ((PlanItem) async -> Void)?
    let onRefresh: (() async -> Void)?
    let isSyncing: Bool
    let syncError: String?

    @State private var isSendingToWatch = false

    public init(
        briefing: TrainingBriefing,
        pendingMarks: Int = 0,
        onToggle: ((PlanItem) -> Void)? = nil,
        onSendToWatch: ((PlanItem) async -> Void)? = nil,
        onRefresh: (() async -> Void)? = nil,
        isSyncing: Bool = false,
        syncError: String? = nil
    ) {
        self.briefing = briefing
        self.pendingMarks = pendingMarks
        self.onToggle = onToggle
        self.onSendToWatch = onSendToWatch
        self.onRefresh = onRefresh
        self.isSyncing = isSyncing
        self.syncError = syncError
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: Brand.Spacing.l) {
                SyncStatusBar(
                    generatedAt: briefing.generatedAt,
                    pendingMarks: pendingMarks,
                    isSyncing: isSyncing,
                    error: syncError,
                    onRefresh: onRefresh
                )
                if let readiness = briefing.readiness {
                    ReadinessCard(readiness: readiness)
                }
                TodayPanel(today: briefing.today)
                if let verdict = TrainingVerdict.make(from: briefing.today) {
                    VerdictBanner(verdict: verdict)
                }
                if let week = briefing.weekZones {
                    WeekZonesPanel(week: week)
                }
                PlanPanel(
                    plan: upcoming,
                    sessions: briefing.week,
                    onToggle: onToggle,
                    onSendToWatch: onSendToWatch.map { action in
                        { item in
                            isSendingToWatch = true
                            await action(item)
                            isSendingToWatch = false
                        }
                    },
                    isSending: isSendingToWatch
                )
                ChartsPanel(series: briefing.series)
            }
            .padding(Brand.Spacing.l)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.groupedSurface)
    }

    private var upcoming: [PlanItem] {
        let today = PlanItem.dayFormatter.string(from: Date())
        return briefing.plan.filter { $0.day >= today }
    }
}

struct TodayPanel: View {
    let today: TodayStatus

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: Brand.Spacing.m)]
    }

    var body: some View {
        SectionCard(
            title: AppLanguage.text("Oggi"), subtitle: AppLanguage.text("recupero e composizione, sulla tua baseline")
        ) {
            LazyVGrid(columns: columns, spacing: Brand.Spacing.m) {
                StatusTile(
                    label: AppLanguage.text("Sonno"),
                    value: today.sleepHours.map { String(format: "%.1f h", locale: AppLanguage.locale, $0) } ?? "—",
                    note: today.sleepHours == nil
                        ? AppLanguage.text("nessun dato stanotte")
                        : sleepNote,
                    tone: sleepTone
                )
                if let sleepHeartRate = today.sleepHeartRate {
                    StatusTile(
                        label: AppLanguage.text("FC nel sonno"),
                        value: String(format: "%.0f", locale: AppLanguage.locale, sleepHeartRate),
                        note: today.sleepHeartRateDeviation.map {
                            String(
                                format: AppLanguage.text("%@%.1f sul mese di %.0f"),
                                $0 >= 0 ? "+" : "", $0, today.sleepHeartRateBaseline ?? 0
                            )
                        } ?? AppLanguage.text("serve qualche notte"),
                        tone: sleepHeartRateTone
                    )
                }
                StatusTile(
                    label: "HRV",
                    value: today.hrv.map { "\(Int($0)) ms" } ?? "—",
                    note: today.hrvDeviation.map {
                        String(
                            format: AppLanguage.text("%@%.0f%% sulla base di %.0f"),
                            $0 >= 0 ? "+" : "", $0, today.hrvBaseline ?? 0
                        )
                    } ?? AppLanguage.text("serve qualche giorno"),
                    tone: deviationTone
                )
                StatusTile(
                    label: AppLanguage.text("FC a riposo"),
                    value: today.restingHeartRate.map { String(format: "%.0f", locale: AppLanguage.locale, $0) } ?? "—",
                    note: today.restingDeviation.map {
                        String(
                            format: AppLanguage.text("%@%.1f sulla base di %.0f"),
                            $0 >= 0 ? "+" : "", $0, today.restingHeartRateBaseline ?? 0
                        )
                    } ?? AppLanguage.text("serve qualche giorno"),
                    tone: restingTone
                )
                StatusTile(
                    label: AppLanguage.text("Peso"),
                    value: today.bodyMass.map { String(format: "%.1f kg", locale: AppLanguage.locale, $0) } ?? "—",
                    note: today.leanMass.map {
                        String(
                            format: AppLanguage.text("magra %.1f · grasso %.1f%%"), $0, today.fatPercent ?? 0
                        )
                    } ?? (today.massDay ?? AppLanguage.text("mai misurato")),
                    tone: .neutral
                )
            }
        }
    }

    private var sleepNote: String {
        let stages = AppLanguage.format(
            "%@′ profondo · %@′ REM", Int(today.deepMinutes ?? 0),
            Int(today.remMinutes ?? 0))
        guard let onset = today.sleepOnset, let wake = today.sleepWake else { return stages }
        return "\(onset) → \(wake)\n\(stages)"
    }

    private var sleepHeartRateTone: StatusTile.Tone {
        guard let delta = today.sleepHeartRateDeviation else { return .neutral }
        return delta > 3 ? .bad : delta < 0 ? .good : .neutral
    }

    private var sleepTone: StatusTile.Tone {
        guard let hours = today.sleepHours else { return .neutral }
        return hours < 6 ? .bad : hours >= 7 ? .good : .neutral
    }

    private var deviationTone: StatusTile.Tone {
        guard let deviation = today.hrvDeviation else { return .neutral }
        return deviation < -10 ? .bad : deviation > 0 ? .good : .neutral
    }

    private var restingTone: StatusTile.Tone {
        guard let delta = today.restingDeviation else { return .neutral }
        return delta > 2 ? .bad : delta < 0 ? .good : .neutral
    }
}

public struct StatusTile: View {
    public enum Tone { case good, bad, neutral }

    let label: String
    let value: String
    let note: String
    let tone: Tone

    public init(label: String, value: String, note: String, tone: Tone) {
        self.label = label
        self.value = value
        self.note = note
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(note)
                .font(.caption)
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Brand.Spacing.m)
        .background(wash, in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous))
    }

    private var colour: Color {
        switch tone {
        case .good: return Brand.good
        case .bad: return Brand.signal
        case .neutral: return .secondary
        }
    }

    private var wash: Color {
        switch tone {
        case .good: return Brand.goodWash.opacity(0.6)
        case .bad: return Brand.signalWash.opacity(0.7)
        case .neutral: return Brand.inkWash.opacity(0.45)
        }
    }
}

public enum TrainingVerdict {
    public struct Result {
        public let text: String
        public let alert: Bool
    }

    public static func make(from today: TodayStatus) -> Result? {
        let sleep = today.sleepHours
        let deviation = today.hrvDeviation

        if let sleep, sleep < 6, let deviation, deviation < -10 {
            return Result(
                text: String(
                    format: AppLanguage.text(
                        "Oggi niente qualità: %.1f h di sonno e HRV %.0f%% sotto la baseline. Sposta la seduta dura, fai 30′ facili o riposa."
                    ),
                    sleep, deviation
                ),
                alert: true
            )
        }
        if let sleep, sleep < 6 {
            return Result(
                text: String(
                    format: AppLanguage.text(
                        "Notte corta, %.1f h. Allenati pure, ma tieni l'intensità sotto controllo e non aggiungere volume."
                    ),
                    sleep
                ),
                alert: true
            )
        }
        if let deviation, deviation < -15 {
            return Result(
                text: String(
                    format: AppLanguage.text(
                        "HRV %.0f%% sotto la baseline. Un giorno solo non fa tendenza: se succede anche domani, salta la qualità."
                    ),
                    deviation
                ),
                alert: true
            )
        }
        if let days = today.longRunDaysAgo, days > 10 {
            return Result(
                text: AppLanguage.format(
                    "Sono %@ giorni dall'ultimo lungo. È la cosa che manca di più: mettilo nel primo giorno libero.",
                    days),
                alert: false
            )
        }
        if let sleep, sleep >= 7, deviation == nil || (deviation ?? 0) > -5 {
            return Result(
                text: String(
                    format: AppLanguage.text("Recupero a posto: %.1f h di sonno, HRV in linea. Oggi puoi caricare."),
                    sleep
                ),
                alert: false
            )
        }
        return nil
    }
}

struct VerdictBanner: View {
    let verdict: TrainingVerdict.Result

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Spacing.m) {
            Image(systemName: verdict.alert ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(verdict.alert ? Brand.signal : Brand.good)
            Text(verdict.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Brand.Spacing.l)
        .background(
            (verdict.alert ? Brand.signalWash : Brand.goodWash).opacity(0.75),
            in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
        )
    }
}
