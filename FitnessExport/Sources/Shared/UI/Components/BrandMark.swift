import FitnessUI
import SwiftUI

struct BrandMark: View {
    var tagline: String? = AppLanguage.text("Da Salute a Garmin Connect e Intervals.icu")
    var logoSize: CGFloat = 56

    var body: some View {
        HStack(spacing: Brand.Spacing.l) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.22, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("FitnessExport")
                    .font(.headline)
                if let tagline {
                    Text(tagline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let version = Self.versionLabel {
                    Text(version)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static var versionLabel: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        let build = info?["CFBundleVersion"] as? String
        return build.map { AppLanguage.format("Versione %@ (%@)", version, $0) }
            ?? AppLanguage.format("Versione %@", version)
    }
}
