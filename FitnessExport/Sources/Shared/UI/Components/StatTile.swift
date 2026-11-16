import FitnessUI
import SwiftUI

enum MetricDirection: Equatable, Sendable {
    case upIsGood
    case downIsGood
    case neutral
}

struct StatTile: View {
    let title: String
    let value: String
    var symbolName: String? = nil

    var change: Double? = nil
    var direction: MetricDirection = .neutral

    var comparisonPlaceholder: String? = nil

    var comparisonValue: String? = nil

    var comparisonName: String = AppLanguage.text("periodo prec.")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let change {
                DeltaLabel(change: change, direction: direction, against: comparisonName)
            } else if let comparisonPlaceholder {
                Text(comparisonPlaceholder)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let comparisonValue {
                Text(AppLanguage.format("prima: %@", comparisonValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Brand.Spacing.l)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

struct DeltaLabel: View {
    let change: Double
    let direction: MetricDirection
    var against: String = AppLanguage.text("periodo prec.")

    var body: some View {
        let percent = Int((change * 100).rounded())
        HStack(spacing: 3) {
            if percent != 0 {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
            }
            Text(
                percent == 0
                    ? AppLanguage.format("invariato vs %@", against)
                    : "\(percent > 0 ? "+" : "")\(percent) % vs \(against)"
            )
            .font(.caption2.weight(.medium).monospacedDigit())
        }
        .foregroundStyle(percent == 0 ? Color.secondary : color)
        .accessibilityLabel(accessibilityText(percent: percent))
    }

    private var isGood: Bool? {
        switch direction {
        case .upIsGood: return change >= 0
        case .downIsGood: return change <= 0
        case .neutral: return nil
        }
    }

    private var color: Color {
        guard let isGood else { return .secondary }
        return isGood ? Brand.good : Brand.bad
    }

    private func accessibilityText(percent: Int) -> String {
        guard percent != 0 else { return AppLanguage.text("invariato rispetto al periodo precedente") }
        let trend =
            percent > 0
            ? AppLanguage.format("più %@ per cento", percent)
            : AppLanguage.format("meno %@ per cento", -percent)
        guard let isGood else {
            return AppLanguage.format("%@ rispetto al periodo precedente", trend)
        }
        return AppLanguage.format(
            "%@ rispetto al periodo precedente, %@", trend,
            isGood ? "in miglioramento" : "in peggioramento")
    }
}
