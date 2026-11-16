import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

public enum Brand {

    public static let ink = Color.adaptive(light: 0x12324F, dark: 0x8CB4E6)

    public static let signal = Color.adaptive(light: 0xC93F26, dark: 0xF0603A)

    public static let inkWash = Color.adaptive(light: 0xE4EBF3, dark: 0x1F2E40)

    public static let signalWash = Color.adaptive(light: 0xFBE9E4, dark: 0x3A241D)

    public static let good = Color.adaptive(light: 0x1E7B34, dark: 0x4CC26A)
    public static let warning = Color.adaptive(light: 0x9A6300, dark: 0xE9A83C)
    public static let bad = Color.adaptive(light: 0xC8322B, dark: 0xF0665E)
    public static let goodWash = Color.adaptive(light: 0xE3F2E6, dark: 0x1B3322)
    public static let warningWash = Color.adaptive(light: 0xFBF0DC, dark: 0x3A2E14)
    public static let badWash = Color.adaptive(light: 0xFAE4E2, dark: 0x3B1F1D)

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
    }

    public enum Radius {
        public static let card: CGFloat = 16
        public static let tile: CGFloat = 14
        public static let control: CGFloat = 10
    }

    public static var cardSurface: Color {
        #if canImport(UIKit)
            return Color(.secondarySystemGroupedBackground)
        #else
            return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    public static var groupedSurface: Color {
        #if canImport(UIKit)
            return Color(.systemGroupedBackground)
        #else
            return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    public static var separator: Color {
        #if canImport(UIKit)
            return Color(.separator)
        #else
            return Color(nsColor: .separatorColor)
        #endif
    }
}

extension Color {

    public static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
            return Color(
                UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(rgbHex: dark)
                        : UIColor(rgbHex: light)
                }
            )
        #elseif canImport(AppKit)
            return Color(
                NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? NSColor(rgbHex: dark)
                        : NSColor(rgbHex: light)
                }
            )
        #else
            return Color(
                red: Double((light >> 16) & 0xFF) / 255,
                green: Double((light >> 8) & 0xFF) / 255,
                blue: Double(light & 0xFF) / 255
            )
        #endif
    }
}

#if canImport(UIKit)
    extension UIColor {
        convenience init(rgbHex hex: UInt32) {
            self.init(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
#elseif canImport(AppKit)
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
#endif

public struct CardBackground: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .background(
                Brand.cardSurface,
                in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
            )
    }
}

extension View {
    public func cardBackground() -> some View {
        modifier(CardBackground())
    }
}
