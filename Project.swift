import Foundation
import ProjectDescription

let bundlePrefix = ProcessInfo.processInfo.environment["FITNESS_BUNDLE_PREFIX"] ?? "org.fitnessexport"
let developmentTeam = ProcessInfo.processInfo.environment["FITNESS_DEVELOPMENT_TEAM"] ?? ""

let deploymentTargets = DeploymentTargets.iOS("17.0")
let destinations: Destinations = [.iPhone, .iPad]

let baseSettings: SettingsDictionary = [
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOLS": "YES",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": "1",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_VERSION": "6.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
]

func settings(_ additional: SettingsDictionary) -> Settings {
    .settings(
        base: baseSettings.merging(additional, uniquingKeysWith: { _, new in new }),
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ],
        defaultSettings: .recommended(excluding: ["CODE_SIGN_IDENTITY"])
    )
}

func multiplatformSettings(_ additional: SettingsDictionary) -> Settings {
    var base = baseSettings
    base.removeValue(forKey: "TARGETED_DEVICE_FAMILY")
    return .settings(
        base: base.merging(additional, uniquingKeysWith: { _, new in new }),
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ],
        defaultSettings: .recommended(excluding: ["CODE_SIGN_IDENTITY"])
    )
}

let project = Project(
    name: "FitnessExport",
    organizationName: "org.fitnessexport",
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": .string(developmentTeam),
            "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
        ],
        configurations: [
            .debug(name: "Debug"),
            .release(name: "Release"),
        ]
    ),
    targets: [

        .target(
            name: "FitnessSyncKit",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "\(bundlePrefix).FitnessExport.synckit",
            deploymentTargets: .multiplatform(iOS: "17.0", macOS: "15.0"),
            sources: ["FitnessSyncKit/Sources/**"],
            dependencies: [],
            settings: multiplatformSettings([
                "MARKETING_VERSION": "1.0"
            ])
        ),
        .target(
            name: "FitnessSyncKitTests",
            destinations: [.iPhone, .iPad, .mac],
            product: .unitTests,
            bundleId: "\(bundlePrefix).FitnessSyncKitTests",
            deploymentTargets: .multiplatform(iOS: "17.0", macOS: "15.0"),
            infoPlist: .default,
            sources: ["FitnessSyncKitTests/Sources/**"],
            dependencies: [.target(name: "FitnessSyncKit")],
            settings: multiplatformSettings([
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "NO",
            ])
        ),

        .target(
            name: "FitnessUI",
            destinations: [.iPhone, .iPad, .mac],
            product: .framework,
            bundleId: "\(bundlePrefix).FitnessExport.ui",
            deploymentTargets: .multiplatform(iOS: "17.0", macOS: "15.0"),
            sources: ["FitnessUI/Sources/**"],
            resources: ["FitnessUI/Resources/**"],
            dependencies: [.target(name: "FitnessSyncKit")],
            settings: multiplatformSettings(["MARKETING_VERSION": "1.0"])
        ),

        .target(
            name: "FitnessExport",
            destinations: destinations,
            product: .app,
            bundleId: "\(bundlePrefix).FitnessExport",
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                "NSHealthShareUsageDescription":
                    "FitnessExport legge i dati fitness da HealthKit per indicizzare e analizzare gli allenamenti.",
                "NSHealthUpdateUsageDescription":
                    "FitnessExport non scrive dati in Salute ma richiede l'accesso per leggere gli allenamenti.",
                "NSCameraUsageDescription": "FitnessExport inquadra il codice mostrato dal Mac per associarlo.",
                "NSLocalNetworkUsageDescription":
                    "FitnessExport invia i dati di Salute al Mac che hai associato, sulla tua rete locale.",
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            ]),
            sources: ["FitnessExport/Sources/**"],
            resources: ["FitnessExport/Assets.xcassets", "FitnessExport/Resources/**"],
            entitlements: .file(path: "FitnessExport/FitnessExport.entitlements"),
            dependencies: [
                .target(name: "FitnessSyncKit"),
                .target(name: "FitnessUI"),
                .sdk(name: "HealthKit", type: .framework),
                .sdk(name: "WorkoutKit", type: .framework),
            ],
            settings: settings([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                "ENABLE_PREVIEWS": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "YES",
            ])
        ),
        .target(
            name: "FitnessExportTests",
            destinations: destinations,
            product: .unitTests,
            bundleId: "\(bundlePrefix).FitnessExportTests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["FitnessExportTests/Sources/**"],
            dependencies: [
                .target(name: "FitnessExport")
            ],
            settings: settings([
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "NO",
            ])
        ),
        .target(
            name: "FitnessExportUITests",
            destinations: destinations,
            product: .uiTests,
            bundleId: "\(bundlePrefix).FitnessExportUITests",
            deploymentTargets: deploymentTargets,
            infoPlist: .default,
            sources: ["FitnessExportUITests/Sources/**"],
            dependencies: [
                .target(name: "FitnessExport")
            ],
            settings: settings([
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "NO",
            ])
        ),

        .target(
            name: "FitnessExportMac",
            destinations: .macOS,
            product: .app,
            bundleId: "\(bundlePrefix).FitnessExportMac",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "NSPrincipalClass": "NSApplication",
                "LSApplicationCategoryType": "public.app-category.healthcare-fitness",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "NSLocalNetworkUsageDescription":
                    "FitnessExport riceve i dati di Salute dal tuo iPhone sulla rete locale.",
            ]),
            sources: ["FitnessExportMac/Sources/**"],
            resources: ["FitnessExportMac/Resources/**"],
            entitlements: .file(path: "FitnessExportMac/Config/FitnessExportMac.entitlements"),
            dependencies: [
                .target(name: "FitnessSyncKit"),
                .target(name: "FitnessUI"),
                .sdk(name: "sqlite3", type: .library),
            ],
            settings: multiplatformSettings([
                "ENABLE_PREVIEWS": "YES",
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "YES",
                "CODE_SIGN_ENTITLEMENTS": "FitnessExportMac/Config/FitnessExportMac.entitlements",
            ])
        ),
        .target(
            name: "FitnessExportMacTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundlePrefix).FitnessExportMacTests",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .default,
            sources: ["FitnessExportMacTests/Sources/**"],
            dependencies: [.target(name: "FitnessExportMac")],
            settings: multiplatformSettings([
                "MARKETING_VERSION": "1.0",
                "SWIFT_EMIT_LOC_STRINGS": "NO",
            ])
        ),
    ]
)
