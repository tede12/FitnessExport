import SwiftUI

public struct SectionCard<Content: View, Accessory: View>: View {
    public let title: String
    public var subtitle: String? = nil
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Brand.Spacing.m) {
            HStack(alignment: .top, spacing: Brand.Spacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
        .padding(Brand.Spacing.l)
        .cardBackground()
    }
}

extension SectionCard where Accessory == EmptyView {
    public init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

public struct IconTile: View {
    public let systemName: String
    public var size: CGFloat = 40
    public var tint: Color = Brand.ink
    public var wash: Color = Brand.inkWash

    public init(
        systemName: String, size: CGFloat = 40, tint: Color = Brand.ink,
        wash: Color = Brand.inkWash
    ) {
        self.systemName = systemName
        self.size = size
        self.tint = tint
        self.wash = wash
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(wash, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}
