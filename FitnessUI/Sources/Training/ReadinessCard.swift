import FitnessSyncKit
import SwiftUI

struct ReadinessCard: View {
    let readiness: Readiness
    @State private var selectedDay: String?
    @State private var showsMethod = false

    private var recentRest: ReadinessPoint? {
        guard let index = readiness.history.firstIndex(where: { $0.day == selected.day }) else {
            return nil
        }
        return readiness.history[max(0, index - 7)..<index].last { !$0.restEpisodes.isEmpty }
    }

    private var todayKey: String { PlanItem.dayFormatter.string(from: Date()) }

    private var selected: ReadinessPoint {
        let day = selectedDay ?? readiness.day
        return readiness.history.first { $0.day == day }
            ?? ReadinessPoint(day: readiness.day, score: readiness.score, components: readiness.components)
    }

    var body: some View {
        SectionCard(
            title: AppLanguage.text("Come sta il tuo corpo"),
            subtitle: AppLanguage.text("punteggio 0–10 · 7,5 è il tuo normale")
        ) {
            VStack(alignment: .leading, spacing: Brand.Spacing.l) {
                Hero(point: selected, isLatest: selected.day == readiness.day)
                if readiness.history.count >= 2 {
                    DayStrip(
                        points: readiness.history,
                        selected: Binding(
                            get: { selectedDay ?? readiness.day },
                            set: { selectedDay = $0 }
                        )
                    )
                }
                if !selected.components.isEmpty {
                    VStack(alignment: .leading, spacing: Brand.Spacing.m) {
                        Text(AppLanguage.text("DA COSA DIPENDE"))
                            .font(.caption2.weight(.semibold))
                            .kerning(0.6)
                            .foregroundStyle(.secondary)
                        ForEach(selected.components) { part in
                            ParameterRow(part: part)
                            if part.id != selected.components.last?.id { Divider() }
                        }
                        if !selected.components.contains(where: { $0.key == "sleep" }) {
                            Divider()
                            Label {
                                Text(ReadinessCopy.missingSleep(isToday: selected.day == todayKey))
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "bed.double").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !selected.restEpisodes.isEmpty {
                    RestEpisodesView(episodes: selected.restEpisodes)
                } else if let recent = recentRest {
                    RecentRestHint(point: recent) { selectedDay = recent.day }
                }
                DisclosureGroup(isExpanded: $showsMethod) {
                    Text(ReadinessCopy.method)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Brand.Spacing.xs)
                } label: {
                    Text(AppLanguage.text("Come si calcola il punteggio")).font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
            .animation(.snappy, value: selected.day)
        }
    }
}

enum ReadinessBand {
    case top, ready, manage, recover

    init(score: Double) {
        switch score {
        case 8...: self = .top
        case 6.5..<8: self = .ready
        case 4.5..<6.5: self = .manage
        default: self = .recover
        }
    }

    var title: String {
        switch self {
        case .top: return AppLanguage.text("Riposato")
        case .ready: return AppLanguage.text("Pronto")
        case .manage: return AppLanguage.text("Un po' affaticato")
        case .recover: return AppLanguage.text("Affaticato")
        }
    }

    var advice: String {
        switch self {
        case .top: return AppLanguage.text("Il corpo ha recuperato bene: giornata buona per la qualità o per il lungo.")
        case .ready: return AppLanguage.text("Sei nel tuo normale: allenati come da piano.")
        case .manage: return AppLanguage.text("Allenati pure, ma niente qualità in più e corse facili davvero facili.")
        case .recover: return AppLanguage.text("Riposo o 30′ in Z1. La seduta dura si sposta, non si salta.")
        }
    }

    var colour: Color {
        switch self {
        case .top, .ready: return Brand.good
        case .manage: return Brand.warning
        case .recover: return Brand.signal
        }
    }
}

private struct Hero: View {
    let point: ReadinessPoint
    let isLatest: Bool

    private var band: ReadinessBand { ReadinessBand(score: point.score) }

    var body: some View {
        HStack(alignment: .center, spacing: Brand.Spacing.l) {
            ScoreRing(score: point.score, band: band)
            VStack(alignment: .leading, spacing: 4) {
                Text(dayLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(band.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(band.colour)
                Text(band.advice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let limiter = point.limiter {
                    Text(
                        AppLanguage.format(
                            "Ti frena: %@", ReadinessCopy.name(limiter.key).lowercased())
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.signal)
                }
            }
        }
    }

    private var dayLabel: String {
        guard let date = point.date else { return point.day }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return AppLanguage.text("OGGI") }
        if calendar.isDateInYesterday(date) {
            return isLatest ? AppLanguage.text("IERI · in attesa delle misure di stamattina") : AppLanguage.text("IERI")
        }
        return ReadinessCopy.longDay.string(from: date).uppercased()
    }
}

private struct ScoreRing: View {
    let score: Double
    let band: ReadinessBand

    var body: some View {
        ZStack {
            Circle().stroke(Brand.inkWash.opacity(0.8), lineWidth: 11)
            Circle()
                .trim(from: 0, to: score / 10)
                .stroke(band.colour, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.1f", locale: AppLanguage.locale, score))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: score))
                Text(AppLanguage.text("su 10")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 124, height: 124)
        .accessibilityElement()
        .accessibilityLabel(
            String(format: AppLanguage.text("Punteggio %.1f su 10, %@"), locale: AppLanguage.locale, score, band.title))
    }
}

private struct DayStrip: View {
    let points: [ReadinessPoint]
    @Binding var selected: String

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.xs) {
            HStack {
                Text(AppLanguage.format("GLI ULTIMI %@ GIORNI", points.count))
                    .font(.caption2.weight(.semibold))
                    .kerning(0.6)
                Spacer()
                Text(AppLanguage.text("scorri ← · tocca un giorno"))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(points) { point in
                            DayChip(point: point, isSelected: point.day == selected) {
                                selected = point.day
                            }
                            .id(point.day)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { proxy.scrollTo(points.last?.day, anchor: .trailing) }
            }
        }
    }
}

private struct DayChip: View {
    let point: ReadinessPoint
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let band = ReadinessBand(score: point.score)
        Button(action: action) {
            VStack(spacing: 2) {
                Text(point.date.map(ReadinessCopy.weekday.string) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(point.date.map(ReadinessCopy.dayNumber.string) ?? "")
                    .font(.caption2.weight(.semibold))
                Text(String(format: "%.1f", locale: AppLanguage.locale, point.score))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(band.colour)

                Image(systemName: "sofa.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .opacity(point.restEpisodes.isEmpty ? 0 : 1)
            }
            .frame(width: 46)
            .padding(.vertical, 6)
            .background(
                band.colour.opacity(isSelected ? 0.22 : 0.08),
                in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .stroke(isSelected ? band.colour : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AppLanguage.format(
                "%@, punteggio %@", point.date.map(ReadinessCopy.longDay.string) ?? point.day,
                String(format: "%.1f", locale: AppLanguage.locale, point.score))
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ParameterRow: View {
    let part: ReadinessComponent

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Label(ReadinessCopy.name(part.key), systemImage: ReadinessCopy.symbol(part.key))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ReadinessCopy.value(part))
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            if let nap = part.napHours {
                Text(
                    String(
                        format: AppLanguage.text("notte %.1f h + pisolino %.0f′"), locale: AppLanguage.locale,
                        part.value - nap, nap * 60)
                )
                .font(.caption.monospacedDigit().weight(.medium))
            }
            Text(ReadinessCopy.what(part.key))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(AppLanguage.text("Il tuo solito:"))
                    .foregroundStyle(.secondary)
                Text(ReadinessCopy.range(part))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                Text(AppLanguage.format("· oggi %@", ReadinessCopy.value(part)))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            RangeGauge(part: part)
                .frame(height: 34)
            Text(ReadinessCopy.meaning(part))
                .font(.footnote)
                .foregroundStyle(ReadinessCopy.isGood(part) == false ? Brand.signal : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RangeGauge: View {
    let part: ReadinessComponent

    private var domain: ClosedRange<Double> {
        let width = max(part.normalHigh - part.normalLow, 0.1)
        let low = min(part.normalLow - width * 0.8, part.value - width * 0.15)
        let high = max(part.normalHigh + width * 0.8, part.value + width * 0.15)
        return low...high
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x = { (value: Double) -> CGFloat in
                CGFloat((value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) * width
            }
            let bandStart = x(part.normalLow)
            let bandEnd = x(part.normalHigh)
            let marker = x(part.value)
            let tone = ReadinessCopy.isGood(part)
            let colour = tone == true ? Brand.good : tone == false ? Brand.signal : Brand.ink

            ZStack(alignment: .topLeading) {
                Capsule().fill(Brand.inkWash.opacity(0.7))
                    .frame(height: 8)
                    .offset(y: 4)
                Capsule().fill(Brand.ink.opacity(0.25))
                    .frame(width: max(bandEnd - bandStart, 4), height: 8)
                    .offset(x: bandStart, y: 4)
                Circle()
                    .fill(colour)
                    .overlay(Circle().stroke(Brand.cardSurface, lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .offset(x: marker - 8)
                Text(ReadinessCopy.edge(part, part.normalLow))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
                    .position(x: bandStart - 30 + 6, y: 26)
                Text(ReadinessCopy.edge(part, part.normalHigh))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                    .position(x: bandEnd + 30 - 6, y: 26)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RecentRestHint: View {
    let point: ReadinessPoint
    let open: () -> Void

    var body: some View {
        if let episode = point.restEpisodes.last {
            Button(action: open) {
                HStack(spacing: Brand.Spacing.s) {
                    Image(systemName: "sofa").foregroundStyle(.secondary)
                    Text(
                        AppLanguage.format(
                            "Riposo probabile: %@ · %@", RestEpisodesView.when(episode),
                            RestEpisodesView.duration(episode.minutes))
                    )
                    .font(.footnote.monospacedDigit())
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(Brand.Spacing.m)
                .background(
                    Brand.inkWash.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppLanguage.text("Apre il giorno con il riposo stimato"))
        }
    }
}

private struct RestEpisodesView: View {
    let episodes: [RestEpisode]

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Label(AppLanguage.text("Riposo probabile"), systemImage: "sofa")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(AppLanguage.text("stimato · non conteggiato"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Brand.inkWash.opacity(0.8), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            ForEach(episodes) { episode in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.when(episode))
                        .font(.footnote.monospacedDigit().weight(.medium))
                    Spacer()
                    Text(Self.duration(episode.minutes))
                        .font(.footnote.monospacedDigit())
                }
            }
            if let first = episodes.first {
                Text(
                    String(
                        format: AppLanguage.text(
                            "Battiti a %.0f bpm, quasi come quando dormi (%.0f), e nessun passo per almeno mezz'ora. Può essere un pisolino o anche solo stare sdraiato fermo: per questo non entra nel sonno del punteggio. Per misurarlo davvero, attiva la modalità Riposo quando ti stendi."
                        ),
                        first.heartRate, first.sleepingHeartRate
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Brand.Spacing.m)
        .background(
            Brand.inkWash.opacity(0.35),
            in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    static func when(_ episode: RestEpisode) -> String {
        "\(day.string(from: episode.start)) \(time.string(from: episode.start))–\(time.string(from: episode.end))"
    }

    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60
            ? "\(total / 60) h \(String(format: "%02d", locale: AppLanguage.locale, total % 60))′" : "\(total)′"
    }

    private static var day: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = "EEE"
        return formatter
    }

    private static var time: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}

enum ReadinessCopy {
    static func name(_ key: String) -> String {
        switch key {
        case "hrv": return "HRV"
        case "resting": return AppLanguage.text("FC a riposo")
        case "sleep": return AppLanguage.text("Sonno")
        case "load": return "Carico"
        default: return key
        }
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "hrv": return "waveform.path.ecg"
        case "resting": return "heart"
        case "sleep": return "bed.double"
        case "load": return "figure.run"
        default: return "circle"
        }
    }

    static func what(_ key: String) -> String {
        switch key {
        case "hrv":
            return AppLanguage.text(
                "Variabilità tra un battito e l'altro, misurata dal Watch di notte. Più è alta, più il corpo è a riposo."
            )
        case "resting":
            return AppLanguage.text(
                "I battiti al minuto a riposo assoluto. Sale quando il corpo è sotto stress: fatica, poco sonno, malattia."
            )
        case "sleep":
            return AppLanguage.text(
                "Tutto il sonno delle 24 ore prima del risveglio: la notte e i pisolini del pomeriggio prima. Sotto le 7 ore il recupero rallenta."
            )
        case "load":
            return AppLanguage.text(
                "Quanto ti sei allenato negli ultimi 7 giorni, rispetto alla tua media delle ultime 6 settimane.")
        default:
            return ""
        }
    }

    static func value(_ part: ReadinessComponent) -> String {
        switch part.key {
        case "sleep": return String(format: "%.1f h", locale: AppLanguage.locale, part.value)
        case "load": return String(format: "%.2f×", locale: AppLanguage.locale, part.value)
        default: return String(format: "%.0f %@", locale: AppLanguage.locale, part.value, part.unit)
        }
    }

    static func edge(_ part: ReadinessComponent, _ value: Double) -> String {
        switch part.key {
        case "sleep": return String(format: "%.1f", locale: AppLanguage.locale, value)
        case "load": return String(format: "%.1f×", locale: AppLanguage.locale, value)
        default: return String(format: "%.0f", locale: AppLanguage.locale, value)
        }
    }

    static func range(_ part: ReadinessComponent) -> String {
        switch part.key {
        case "sleep": return String(format: "%.1f–%.1f h", locale: AppLanguage.locale, part.normalLow, part.normalHigh)
        case "load": return String(format: "%.1f–%.1f×", locale: AppLanguage.locale, part.normalLow, part.normalHigh)
        default:
            return String(
                format: "%.0f–%.0f %@", locale: AppLanguage.locale, part.normalLow, part.normalHigh, part.unit)
        }
    }

    static func isGood(_ part: ReadinessComponent) -> Bool? {
        switch part.key {
        case "sleep":
            return part.value >= 7.5 ? true : part.value < 6.5 ? false : nil
        case "load":
            return part.value > part.normalHigh ? false : nil
        case "resting":
            return part.position == .within ? nil : part.position == .below
        default:
            return part.position == .within ? nil : part.position == .above
        }
    }

    static func meaning(_ part: ReadinessComponent) -> String {
        let usual = AppLanguage.format("il tuo solito è %@", range(part))
        switch (part.key, part.position) {
        case ("hrv", .above):
            return AppLanguage.format(
                "Più alta del solito (%@): il corpo ha recuperato bene.", usual)
        case ("hrv", .below):
            return AppLanguage.format(
                "Più bassa del solito (%@): il corpo sta ancora recuperando. Se resta bassa 2–3 giorni, togli intensità.",
                usual)
        case ("hrv", .within):
            return AppLanguage.format("Nel tuo solito (%@): niente da segnalare.", range(part))
        case ("resting", .below):
            return AppLanguage.format("Più bassa del solito (%@): buon segno di recupero.", usual)
        case ("resting", .above):
            return AppLanguage.format(
                "Più alta del solito (%@): il corpo è sotto sforzo. Se resta alta 2–3 giorni, riposa.",
                usual)
        case ("resting", .within):
            return AppLanguage.format("Nel tuo solito (%@): niente da segnalare.", range(part))
        case ("sleep", _):
            let need =
                part.value >= 7.5
                ? AppLanguage.text("Abbastanza per recuperare.")
                : String(
                    format: AppLanguage.text("Te ne mancano %.1f per le 8 h che servono in un blocco di allenamento."),
                    locale: AppLanguage.locale, 8 - part.value)
            return AppLanguage.format(
                "%@ Di solito dormi %@.", need, range(part))
        case ("load", .above):
            return AppLanguage.text(
                "Ti stai allenando più del solito (la fascia sicura è 0,8–1,3×): la fatica si accumula prima che la senti."
            )
        case ("load", .below):
            return AppLanguage.text("Ti stai allenando meno del solito: settimana di scarico, il corpo recupera.")
        default:
            return AppLanguage.text("Carico in linea con quello a cui sei abituato (fascia sicura 0,8–1,3×).")
        }
    }

    static func missingSleep(isToday: Bool) -> String {
        isToday
            ? AppLanguage.text(
                "Sonno di stanotte non ancora arrivato: il Watch lo scrive in Salute quando chiude la notte, a volte un'ora dopo il risveglio. Il punteggio per ora non lo conta; risincronizza più tardi."
            )
            : AppLanguage.text("Nessun dato di sonno per questa notte: il punteggio non lo conta.")
    }

    static var method: String { AppLanguage.text("readiness.method") }

    static var weekday: DateFormatter { formatter("EEE") }
    static var dayNumber: DateFormatter { formatter("d MMM") }
    static var longDay: DateFormatter { formatter("EEEE d MMMM") }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateFormat = format
        return formatter
    }
}
