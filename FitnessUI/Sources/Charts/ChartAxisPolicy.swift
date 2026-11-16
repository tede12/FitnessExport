import Charts
import Foundation

public enum ChartAxisPolicy {

    private static let integerSteps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500]

    public static func labelBudget(plotWidth: CGFloat, labelWidth: CGFloat) -> Int {
        guard plotWidth > 0, labelWidth > 0 else { return 1 }
        return max(2, Int(plotWidth / (labelWidth + 8)))
    }

    public static func integerStride(count: Int, maxLabels: Int) -> Int {
        guard count > 0 else { return 1 }
        let budget = max(1, maxLabels)

        for step in integerSteps where count / step <= budget {
            return step
        }
        return Int((Double(count) / Double(budget)).rounded(.up))
    }

    public static func integerTicks(count: Int, maxLabels: Int) -> [Int] {
        guard count > 0 else { return [] }
        let step = integerStride(count: count, maxLabels: maxLabels)
        guard step > 1 else { return Array(1...count) }
        var ticks = Array(stride(from: step, through: count, by: step))
        if ticks.isEmpty { ticks = [count] }
        return ticks
    }

    public static func valueTicks(
        min: Double, max: Double, maxLabels: Int, steps: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500]
    ) -> [Double] {
        guard min.isFinite, max.isFinite else { return [] }
        let low = Swift.min(min, max)
        let high = Swift.max(min, max)
        let budget = Swift.max(2, maxLabels)
        for step in steps {
            let ticks = boundingMultiples(of: step, from: low, through: high)
            if ticks.count <= budget { return ticks }
        }
        return boundingMultiples(of: steps.last ?? 1, from: low, through: high)
    }

    public static func paceTicks(min: Double, max: Double, maxLabels: Int) -> [Double] {
        valueTicks(min: min, max: max, maxLabels: maxLabels, steps: [5, 10, 15, 30, 60, 120, 300, 600])
    }

    public static func durationTicks(total: TimeInterval, maxLabels: Int) -> [Double] {
        guard total.isFinite, total > 0 else { return [] }
        return valueTicks(
            min: 0, max: total, maxLabels: maxLabels, steps: [30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200])
    }

    public static func domain(of ticks: [Double]) -> ClosedRange<Double>? {
        guard let first = ticks.first, let last = ticks.last, first < last else { return nil }
        return first...last
    }

    private static func boundingMultiples(of step: Double, from low: Double, through high: Double) -> [Double] {
        guard step > 0 else { return [] }
        let lower = (low / step).rounded(.down) * step
        var upper = (high / step).rounded(.up) * step
        if upper <= lower { upper = lower + step }
        return stride(from: lower, through: upper + step / 1_000, by: step).map { $0 }
    }

    public struct DateAxis: Equatable {
        public enum Unit: Equatable {
            case day, week, month, quarter, year

            public var component: Calendar.Component {
                switch self {
                case .day: return .day
                case .week: return .weekOfYear
                case .month, .quarter: return .month
                case .year: return .year
                }
            }
        }

        public let unit: Unit

        public let count: Int

        public init(unit: Unit, count: Int) {
            self.unit = unit
            self.count = count
        }

        public var format: Date.FormatStyle {
            let base = Date.FormatStyle(locale: AppLanguage.locale)
            switch unit {
            case .day, .week: return base.day().month(.abbreviated)
            case .month: return base.month(.abbreviated)
            case .quarter: return base.month(.abbreviated).year(.twoDigits)
            case .year: return base.year()
            }
        }

        public func format(spanningYears: Bool) -> Date.FormatStyle {
            guard spanningYears, unit == .month else { return format }
            return Date.FormatStyle(locale: AppLanguage.locale).month(.abbreviated).year(.twoDigits)
        }
    }

    public static func dateAxis(span: TimeInterval, maxLabels: Int, spansYears: Bool = false) -> DateAxis {

        let narrow = Double(max(2, maxLabels)) + 0.5
        let wide = Double(max(2, maxLabels)) * 0.65 + 0.5
        let monthBudget = spansYears ? wide : narrow
        let days = max(span / 86_400, 1)
        let weeks = days / 7
        let months = days / 30.44
        let years = days / 365.25

        if days <= wide { return DateAxis(unit: .day, count: 1) }
        if weeks <= wide { return DateAxis(unit: .week, count: 1) }
        if weeks / 2 <= wide { return DateAxis(unit: .week, count: 2) }
        if months <= monthBudget { return DateAxis(unit: .month, count: 1) }
        if months / 2 <= monthBudget { return DateAxis(unit: .month, count: 2) }
        if months / 3 <= wide { return DateAxis(unit: .quarter, count: 3) }
        if months / 6 <= wide { return DateAxis(unit: .quarter, count: 6) }
        if years <= narrow { return DateAxis(unit: .year, count: 1) }
        return DateAxis(unit: .year, count: Int((years / narrow).rounded(.up)))
    }
}

public struct AxisBoundsMarks: ChartContent {
    public init(ticks: [Double], axis: Axis) {
        self.ticks = ticks
        self.axis = axis
    }

    public enum Axis { case x, y }

    public let ticks: [Double]
    public let axis: Axis

    public var body: some ChartContent {
        if let first = ticks.first, let last = ticks.last {
            ForEach([first, last], id: \.self) { bound in
                switch axis {
                case .x:
                    RuleMark(x: .value(AppLanguage.text("Limite"), bound)).opacity(0).accessibilityHidden(true)
                case .y:
                    RuleMark(y: .value(AppLanguage.text("Limite"), bound)).opacity(0).accessibilityHidden(true)
                }
            }
        }
    }
}
