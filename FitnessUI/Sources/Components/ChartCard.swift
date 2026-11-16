import SwiftUI

public struct ChartCard<Content: View, Table: View>: View {
    public let title: String
    public let subtitle: String
    @Binding var showTable: Bool
    public var loading: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let table: () -> Table
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        subtitle: String,
        showTable: Binding<Bool>,
        loading: String? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder table: @escaping () -> Table
    ) {
        self.title = title
        self.subtitle = subtitle
        _showTable = showTable
        self.loading = loading
        self.content = content
        self.table = table
    }

    public var body: some View {
        SectionCard(title: title, subtitle: subtitle) {
            HStack(spacing: Brand.Spacing.s) {
                if let loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(loading).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if Table.self != EmptyView.self {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showTable.toggle() }
                    } label: {
                        Image(systemName: showTable ? "chart.xyaxis.line" : "tablecells")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .accessibilityLabel(
                        showTable ? AppLanguage.text("Mostra grafico") : AppLanguage.text("Mostra tabella"))
                }
            }
        } content: {
            if showTable {
                table()
            } else {
                content()
            }
        }
    }
}

extension ChartCard where Table == EmptyView {
    public init(title: String, subtitle: String, loading: String? = nil, @ViewBuilder content: @escaping () -> Content)
    {
        self.init(
            title: title, subtitle: subtitle, showTable: .constant(false), loading: loading, content: content,
            table: { EmptyView() })
    }
}

public struct ChartTooltip: View {
    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    public let title: String
    public let lines: [String]

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                .strokeBorder(Brand.separator.opacity(0.5), lineWidth: 0.5)
        )
    }
}

public struct ChartLegend: View {
    public enum Swatch {
        case line(Color)
        case dot(Color)
        case band(Color)
        case bar(Color)
    }

    public struct Item: Identifiable {
        let label: String
        let swatch: Swatch
        public var id: String { label }

        public init(label: String, swatch: Swatch) {
            self.label = label
            self.swatch = swatch
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: Brand.Spacing.m) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    swatchView(item.swatch)
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func swatchView(_ swatch: Swatch) -> some View {
        switch swatch {
        case .line(let color):
            Capsule().fill(color).frame(width: 14, height: 2)
        case .dot(let color):
            Circle().fill(color).frame(width: 8, height: 8)
        case .band(let color):
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 8)
        case .bar(let color):
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 10)
        }
    }
}

public struct DataTable: View {
    public let header: [String]
    public let rows: [[String]]
    public var limit = 30

    public init(header: [String], rows: [[String]], limit: Int = 30) {
        self.header = header
        self.rows = rows
        self.limit = limit
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Brand.Spacing.m, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, title in
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(Array(rows.prefix(limit).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.caption.monospacedDigit())
                    }
                }
            }
            if rows.count > limit {
                GridRow {
                    Text(AppLanguage.format("… e altre %@ righe", rows.count - limit))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(header.count)
                }
            }
        }
    }
}
