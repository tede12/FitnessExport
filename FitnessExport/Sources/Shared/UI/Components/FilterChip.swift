import FitnessUI
import SwiftUI

struct FilterChip: View {
    let title: String
    var symbolName: String? = nil
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? Color(.systemBackground).opacity(0.8) : Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 36)

            .foregroundStyle(isSelected ? Color(.systemBackground) : Color.primary)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Brand.ink : Color(.tertiarySystemFill))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(count.map { "\($0)" } ?? "")
    }
}

struct ChipRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Brand.Spacing.s) {
                content()
            }
            .padding(.horizontal, Brand.Spacing.l)
            .padding(.vertical, Brand.Spacing.xs)
        }
    }
}
