import FitnessUI
import SwiftUI

struct StatusBanner<Actions: View>: View {
    enum Kind {
        case info, warning, error, success

        var symbolName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return Brand.ink
            case .warning: return Brand.warning
            case .error: return Brand.bad
            case .success: return Brand.good
            }
        }

        var wash: Color {
            switch self {
            case .info: return Brand.inkWash
            case .warning: return Brand.warningWash
            case .error: return Brand.badWash
            case .success: return Brand.goodWash
            }
        }
    }

    let kind: Kind
    let title: String
    var message: String? = nil
    @ViewBuilder let actions: () -> Actions

    init(kind: Kind, title: String, message: String? = nil, @ViewBuilder actions: @escaping () -> Actions) {
        self.kind = kind
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Spacing.m) {
            Image(systemName: kind.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(Brand.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.wash, in: RoundedRectangle(cornerRadius: Brand.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension StatusBanner where Actions == EmptyView {
    init(kind: Kind, title: String, message: String? = nil) {
        self.init(kind: kind, title: title, message: message, actions: { EmptyView() })
    }
}
