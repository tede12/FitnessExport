import SwiftUI

public enum ChartPalette {

    public static let series = Color.adaptive(light: 0x2F6FB7, dark: 0x3987E5)

    public static let highlight = Brand.signal

    public static let context = Color.adaptive(light: 0xA6A5A0, dark: 0x6E6E6B)

    public static let grid = Color.adaptive(light: 0xE5E5EA, dark: 0x3A3A3C)

    public static let band = series.opacity(0.14)

    public static let good = Brand.good
    public static let bad = Brand.bad

    public static let sequential: [Color] = [
        Color.adaptive(light: 0x93B6E2, dark: 0x2B5A8F),
        Color.adaptive(light: 0x6A9CD7, dark: 0x3572B3),
        Color.adaptive(light: 0x4A83C8, dark: 0x4A8AD1),
        Color.adaptive(light: 0x2F6FB7, dark: 0x6FA6E3),
        Color.adaptive(light: 0x1B4A80, dark: 0x9CC3F0),
    ]

    public static let empty = Color.adaptive(light: 0xE9E9EE, dark: 0x2C2C2E)

    public static func sequentialColor(_ progress: Double) -> Color {
        let clamped = min(max(progress, 0), 1)
        let index = Int((clamped * Double(sequential.count - 1)).rounded())
        return sequential[index]
    }
}
