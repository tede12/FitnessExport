import AppKit
import SwiftUI

enum BrandMac {
    static let ink = Color.adaptive(light: 0x12324F, dark: 0x8CB4E6)
    static let signal = Color.adaptive(light: 0xC93F26, dark: 0xF0603A)
    static let inkWash = Color.adaptive(light: 0xE4EBF3, dark: 0x1F2E40)
    static let good = Color.adaptive(light: 0x1E7B34, dark: 0x4CC26A)
    static let warning = Color.adaptive(light: 0x9A6300, dark: 0xE9A83C)

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }
}

extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgbHex: isDark ? dark : light)
            }
        )
    }
}

extension NSColor {
    convenience init(rgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
