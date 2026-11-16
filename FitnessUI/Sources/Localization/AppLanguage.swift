import Foundation
import SwiftUI

private final class LocalizationBundleToken {}

public enum AppLanguage {
    public static let preferenceKey = "app.language"

    public static var code: String {
        code(for: UserDefaults.standard.string(forKey: preferenceKey) ?? "system")
    }

    private static func code(for choice: String) -> String {
        if choice == "en" || choice == "it" { return choice }
        return Locale.preferredLanguages.first?.hasPrefix("it") == true ? "it" : "en"
    }

    public static var locale: Locale { locale(for: code) }

    public static func locale(for preference: String) -> Locale {
        Locale(identifier: code(for: preference))
    }

    public static func text(_ key: String) -> String {
        let resources = Bundle(for: LocalizationBundleToken.self)
        guard let path = resources.path(forResource: code, ofType: "lproj"),
            let localized = Bundle(path: path)
        else { return key }
        return localized.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func count(_ key: String, _ value: Int) -> String {
        String(format: text(key), locale: locale, arguments: [value])
    }

    public static func format(_ key: String, _ arguments: any CustomStringConvertible...) -> String {
        String(format: text(key), locale: locale, arguments: arguments.map { $0.description })
    }
}

public struct LanguageSettingsSection: View {
    @AppStorage(AppLanguage.preferenceKey) private var choice = "system"

    public init() {}

    public var body: some View {
        Section {
            Picker(AppLanguage.text("Lingua"), selection: $choice) {
                Text(AppLanguage.text("Sistema")).tag("system")
                Text("English").tag("en")
                Text("Italiano").tag("it")
            }
            .accessibilityIdentifier("settings.language")
        }
    }
}

public struct PersonalSetupSection: View {
    public init() {}

    public var body: some View {
        Section {
            Text(
                AppLanguage.text(
                    "Collega il server MCP dal Mac per configurare obiettivi, disponibilità, zone e documenti. Apri la guida nel repository: docs/personal-setup.md."
                ))
            Text(
                AppLanguage.text(
                    "I documenti restano nell'archivio locale. Condividili con il client AI solo se lo scegli; conferma i valori estratti prima di salvarli."
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text(AppLanguage.text("Configurazione personale"))
        }
    }
}
