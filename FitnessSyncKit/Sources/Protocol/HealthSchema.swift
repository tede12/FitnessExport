import Foundation

public enum MetricAggregation: String, Codable, Sendable {
    case discrete
    case cumulative
}

public enum MetricFamily: String, Codable, Sendable, CaseIterable {

    case recovery

    case sleep

    case body

    case fitness

    case activity

    case workout

    case nutrition

    case vitals
}

public struct MetricDescriptor: Codable, Sendable, Hashable, Identifiable {

    public let key: String

    public let identifier: String

    public let unit: String
    public let aggregation: MetricAggregation
    public let family: MetricFamily

    public let isCategory: Bool

    public let title: String

    public var id: String { key }

    public init(
        key: String,
        identifier: String,
        unit: String,
        aggregation: MetricAggregation,
        family: MetricFamily,
        isCategory: Bool = false,
        title: String
    ) {
        self.key = key
        self.identifier = identifier
        self.unit = unit
        self.aggregation = aggregation
        self.family = family
        self.isCategory = isCategory
        self.title = title
    }
}

public enum HealthCatalog {
    public static let metrics: [MetricDescriptor] = quantities + categories

    public static let highVolumeKeys: Set<String> = [
        "heart_rate", "step_count", "active_energy", "basal_energy",
        "distance_walking_running", "distance_cycling",
    ]

    public static func metric(forKey key: String) -> MetricDescriptor? {
        index[key]
    }

    private static let index: [String: MetricDescriptor] = Dictionary(
        uniqueKeysWithValues: metrics.map { ($0.key, $0) }
    )

    private static let quantities: [MetricDescriptor] = [
        .init(
            key: "heart_rate", identifier: "HKQuantityTypeIdentifierHeartRate",
            unit: "count/min", aggregation: .discrete, family: .workout,
            title: "Frequenza cardiaca"),
        .init(
            key: "resting_heart_rate", identifier: "HKQuantityTypeIdentifierRestingHeartRate",
            unit: "count/min", aggregation: .discrete, family: .recovery,
            title: "FC a riposo"),
        .init(
            key: "walking_heart_rate", identifier: "HKQuantityTypeIdentifierWalkingHeartRateAverage",
            unit: "count/min", aggregation: .discrete, family: .recovery,
            title: "FC media in camminata"),
        .init(
            key: "hrv_sdnn", identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            unit: "ms", aggregation: .discrete, family: .recovery,
            title: "Variabilità cardiaca (SDNN)"),
        .init(
            key: "workout_effort", identifier: "HKQuantityTypeIdentifierWorkoutEffortScore",
            unit: "appleEffortScore", aggregation: .discrete, family: .workout,
            title: "Sforzo percepito della seduta"),
        .init(
            key: "estimated_workout_effort",
            identifier: "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore",
            unit: "appleEffortScore", aggregation: .discrete, family: .workout,
            title: "Sforzo stimato della seduta"),
        .init(
            key: "physical_effort", identifier: "HKQuantityTypeIdentifierPhysicalEffort",
            unit: "kcal/(kg*hr)", aggregation: .discrete, family: .activity,
            title: "Sforzo fisico"),
        .init(
            key: "body_mass_index", identifier: "HKQuantityTypeIdentifierBodyMassIndex",
            unit: "count", aggregation: .discrete, family: .body, title: "Indice di massa corporea"),
        .init(
            key: "waist_circumference",
            identifier: "HKQuantityTypeIdentifierWaistCircumference",
            unit: "cm", aggregation: .discrete, family: .body, title: "Girovita"),
        .init(
            key: "heart_rate_recovery_1min",
            identifier: "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute",
            unit: "count/min", aggregation: .discrete, family: .recovery,
            title: "Recupero FC a 1 minuto"),
        .init(
            key: "respiratory_rate", identifier: "HKQuantityTypeIdentifierRespiratoryRate",
            unit: "count/min", aggregation: .discrete, family: .recovery,
            title: "Frequenza respiratoria"),
        .init(
            key: "oxygen_saturation", identifier: "HKQuantityTypeIdentifierOxygenSaturation",
            unit: "%", aggregation: .discrete, family: .recovery,
            title: "Saturazione di ossigeno"),
        .init(
            key: "wrist_temperature",
            identifier: "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
            unit: "degC", aggregation: .discrete, family: .recovery,
            title: "Temperatura al polso nel sonno"),
        .init(
            key: "sleeping_breathing_disturbances",
            identifier: "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances",
            unit: "count", aggregation: .discrete, family: .sleep,
            title: "Disturbi respiratori nel sonno"),
        .init(
            key: "body_temperature", identifier: "HKQuantityTypeIdentifierBodyTemperature",
            unit: "degC", aggregation: .discrete, family: .vitals,
            title: "Temperatura corporea"),

        .init(
            key: "body_mass", identifier: "HKQuantityTypeIdentifierBodyMass",
            unit: "kg", aggregation: .discrete, family: .body, title: "Peso"),
        .init(
            key: "lean_body_mass", identifier: "HKQuantityTypeIdentifierLeanBodyMass",
            unit: "kg", aggregation: .discrete, family: .body, title: "Massa magra"),
        .init(
            key: "body_fat_percentage", identifier: "HKQuantityTypeIdentifierBodyFatPercentage",
            unit: "%", aggregation: .discrete, family: .body, title: "Massa grassa"),
        .init(
            key: "height", identifier: "HKQuantityTypeIdentifierHeight",
            unit: "m", aggregation: .discrete, family: .body, title: "Altezza"),

        .init(
            key: "vo2_max", identifier: "HKQuantityTypeIdentifierVO2Max",
            unit: "ml/(kg*min)", aggregation: .discrete, family: .fitness,
            title: "VO2 max"),
        .init(
            key: "six_minute_walk", identifier: "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",
            unit: "m", aggregation: .discrete, family: .fitness,
            title: "Test del cammino (6 min)"),

        .init(
            key: "step_count", identifier: "HKQuantityTypeIdentifierStepCount",
            unit: "count", aggregation: .cumulative, family: .activity, title: "Passi"),
        .init(
            key: "active_energy", identifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            unit: "kcal", aggregation: .cumulative, family: .activity,
            title: "Energia attiva"),
        .init(
            key: "basal_energy", identifier: "HKQuantityTypeIdentifierBasalEnergyBurned",
            unit: "kcal", aggregation: .cumulative, family: .activity,
            title: "Energia a riposo"),
        .init(
            key: "exercise_time", identifier: "HKQuantityTypeIdentifierAppleExerciseTime",
            unit: "min", aggregation: .cumulative, family: .activity,
            title: "Minuti di esercizio"),
        .init(
            key: "stand_time", identifier: "HKQuantityTypeIdentifierAppleStandTime",
            unit: "min", aggregation: .cumulative, family: .activity,
            title: "Minuti in piedi"),
        .init(
            key: "flights_climbed", identifier: "HKQuantityTypeIdentifierFlightsClimbed",
            unit: "count", aggregation: .cumulative, family: .activity,
            title: "Piani saliti"),
        .init(
            key: "time_in_daylight", identifier: "HKQuantityTypeIdentifierTimeInDaylight",
            unit: "min", aggregation: .cumulative, family: .activity,
            title: "Tempo alla luce del giorno"),

        .init(
            key: "distance_walking_running",
            identifier: "HKQuantityTypeIdentifierDistanceWalkingRunning",
            unit: "m", aggregation: .cumulative, family: .workout,
            title: "Distanza a piedi"),
        .init(
            key: "distance_cycling", identifier: "HKQuantityTypeIdentifierDistanceCycling",
            unit: "m", aggregation: .cumulative, family: .workout,
            title: "Distanza in bici"),
        .init(
            key: "distance_swimming", identifier: "HKQuantityTypeIdentifierDistanceSwimming",
            unit: "m", aggregation: .cumulative, family: .workout,
            title: "Distanza a nuoto"),
        .init(
            key: "running_power", identifier: "HKQuantityTypeIdentifierRunningPower",
            unit: "W", aggregation: .discrete, family: .workout, title: "Potenza di corsa"),
        .init(
            key: "running_speed", identifier: "HKQuantityTypeIdentifierRunningSpeed",
            unit: "m/s", aggregation: .discrete, family: .workout, title: "Velocità di corsa"),
        .init(
            key: "running_stride_length",
            identifier: "HKQuantityTypeIdentifierRunningStrideLength",
            unit: "m", aggregation: .discrete, family: .workout, title: "Lunghezza falcata"),
        .init(
            key: "running_vertical_oscillation",
            identifier: "HKQuantityTypeIdentifierRunningVerticalOscillation",
            unit: "cm", aggregation: .discrete, family: .workout,
            title: "Oscillazione verticale"),
        .init(
            key: "running_ground_contact_time",
            identifier: "HKQuantityTypeIdentifierRunningGroundContactTime",
            unit: "ms", aggregation: .discrete, family: .workout,
            title: "Tempo di contatto al suolo"),
        .init(
            key: "cycling_power", identifier: "HKQuantityTypeIdentifierCyclingPower",
            unit: "W", aggregation: .discrete, family: .workout, title: "Potenza in bici"),
        .init(
            key: "cycling_speed", identifier: "HKQuantityTypeIdentifierCyclingSpeed",
            unit: "m/s", aggregation: .discrete, family: .workout, title: "Velocità in bici"),
        .init(
            key: "cycling_cadence", identifier: "HKQuantityTypeIdentifierCyclingCadence",
            unit: "count/min", aggregation: .discrete, family: .workout,
            title: "Cadenza in bici"),
        .init(
            key: "swimming_stroke_count",
            identifier: "HKQuantityTypeIdentifierSwimmingStrokeCount",
            unit: "count", aggregation: .cumulative, family: .workout, title: "Bracciate"),
        .init(
            key: "water_temperature", identifier: "HKQuantityTypeIdentifierWaterTemperature",
            unit: "degC", aggregation: .discrete, family: .workout,
            title: "Temperatura dell'acqua"),

        .init(
            key: "dietary_energy", identifier: "HKQuantityTypeIdentifierDietaryEnergyConsumed",
            unit: "kcal", aggregation: .cumulative, family: .nutrition,
            title: "Energia assunta"),
        .init(
            key: "dietary_water", identifier: "HKQuantityTypeIdentifierDietaryWater",
            unit: "ml", aggregation: .cumulative, family: .nutrition, title: "Acqua"),
        .init(
            key: "dietary_protein", identifier: "HKQuantityTypeIdentifierDietaryProtein",
            unit: "g", aggregation: .cumulative, family: .nutrition, title: "Proteine"),
        .init(
            key: "dietary_carbohydrates",
            identifier: "HKQuantityTypeIdentifierDietaryCarbohydrates",
            unit: "g", aggregation: .cumulative, family: .nutrition, title: "Carboidrati"),

        .init(
            key: "blood_pressure_systolic",
            identifier: "HKQuantityTypeIdentifierBloodPressureSystolic",
            unit: "mmHg", aggregation: .discrete, family: .vitals,
            title: "Pressione sistolica"),
        .init(
            key: "blood_pressure_diastolic",
            identifier: "HKQuantityTypeIdentifierBloodPressureDiastolic",
            unit: "mmHg", aggregation: .discrete, family: .vitals,
            title: "Pressione diastolica"),
        .init(
            key: "blood_glucose", identifier: "HKQuantityTypeIdentifierBloodGlucose",
            unit: "mg/dL", aggregation: .discrete, family: .vitals, title: "Glicemia"),
    ]

    private static let categories: [MetricDescriptor] = [
        .init(
            key: "sleep_analysis", identifier: "HKCategoryTypeIdentifierSleepAnalysis",
            unit: "", aggregation: .discrete, family: .sleep, isCategory: true,
            title: "Sonno"),
        .init(
            key: "mindful_session", identifier: "HKCategoryTypeIdentifierMindfulSession",
            unit: "", aggregation: .discrete, family: .recovery, isCategory: true,
            title: "Sessione di respirazione"),
    ]
}
