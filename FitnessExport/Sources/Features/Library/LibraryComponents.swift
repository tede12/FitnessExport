import FitnessUI
import SwiftUI

struct IndexStatusRow: View {
    let title: String
    let subtitle: String
    let isRefreshing: Bool
    let isReady: Bool

    var body: some View {
        HStack(spacing: Brand.Spacing.m) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .frame(width: 40, height: 40)
                        .background(Brand.inkWash, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                } else {
                    IconTile(
                        systemName: isReady ? "checkmark.seal.fill" : "tray",
                        tint: isReady ? Brand.good : Brand.ink,
                        wash: isReady ? Brand.goodWash : Brand.inkWash
                    )
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyIndexView: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: Brand.Spacing.l) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(AppLanguage.text("Leggi gli allenamenti da Salute"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(
                    AppLanguage.text(
                        "FitnessExport crea un indice locale delle attività registrate con Apple Watch. I dati restano sul telefono."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            Button(action: action) {
                HStack {
                    if isRefreshing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.down.heart")
                    }
                    Text(
                        isRefreshing ? AppLanguage.text("Lettura in corso…") : AppLanguage.text("Crea indice da Salute")
                    )
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.signal)
            .controlSize(.large)
            .disabled(isRefreshing)
            .accessibilityIdentifier("index.create.button")
        }
        .padding(.vertical, Brand.Spacing.m)
        .frame(maxWidth: .infinity)
    }
}

struct WorkoutRow: View {
    let workout: WorkoutListItem
    let isSelected: Bool
    let uploadedTo: [UploadPlatform]
    let onToggle: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Brand.Spacing.m) {

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Brand.ink : Color(.tertiaryLabel))
                    .accessibilityHidden(true)

                IconTile(
                    systemName: workout.activityType.symbolName,
                    wash: isSelected ? Color(.secondarySystemGroupedBackground) : Brand.inkWash
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workout.activityType.title)
                            .font(.headline)
                        if workout.hasHeartRateData {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(AppLanguage.text("Con dati di frequenza cardiaca"))
                        }
                        ForEach(uploadedTo, id: \.self) { platform in
                            UploadBadge(platform: platform)
                        }
                    }
                    Text(WorkoutFormatting.workoutDate(workout.startDate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(metricsLine)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: Brand.Spacing.xs)

                Button(action: onOpenDetail) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(AppLanguage.text("Dettaglio e grafici"))
                .accessibilityIdentifier("workout.detail.button")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Brand.inkWash : Color(.secondarySystemGroupedBackground))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var metricsLine: String {
        var parts = [WorkoutFormatting.duration(workout.duration)]
        if let distance = WorkoutFormatting.distanceCompact(workout.distanceInMeters) {
            parts.append(distance)
        }
        if let pace = WorkoutFormatting.pace(distanceInMeters: workout.distanceInMeters, duration: workout.duration) {
            parts.append(pace)
        }
        return parts.joined(separator: " · ")
    }
}

struct UploadBadge: View {
    let platform: UploadPlatform

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text(platform.badge)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(Brand.ink)
        .background(Brand.inkWash, in: Capsule())
        .accessibilityLabel(AppLanguage.format("Caricato su %@", platform.title))
    }
}
