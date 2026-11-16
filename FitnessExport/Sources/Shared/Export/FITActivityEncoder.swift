import FitnessUI
import Foundation

struct FITActivityEncoder: Sendable {
    struct Options: Sendable {
        var recordInterval: TimeInterval = 1
        var timeZone: TimeZone = .current
    }

    struct RecordSample: Equatable {
        let timestamp: Date
        let distance: Double?
        let speed: Double?
        let point: RoutePoint?
        let heartRate: Double?
        let cadence: Double?
        let power: Double?
        let temperature: Double?
        let verticalOscillation: Double?
        let groundContactTime: Double?
        let strideLength: Double?
    }

    private static let manufacturerDevelopment: Int64 = 255
    private static let holdWindow: TimeInterval = 60

    var options = Options()

    func encode(_ data: WorkoutExportData) -> Data {
        var writer = FITFileWriter()
        let timeline = Timeline(data: data, holdWindow: Self.holdWindow)
        let records = sampleRecords(data, timeline: timeline)
        let laps = buildLaps(data, records: records)

        writeHeader(&writer, data: data)
        writeWorkoutSteps(&writer, laps: laps, data: data)
        writeTimerEventsAndRecords(&writer, data: data, records: records)
        writeLengths(&writer, data: data)
        for (index, lap) in laps.enumerated() {
            writeLap(&writer, lap: lap, index: index, data: data)
        }
        writeSession(&writer, data: data, records: records, laps: laps)
        writeActivity(&writer, data: data)
        return writer.finish()
    }

    func sampleRecords(_ data: WorkoutExportData, timeline: Timeline) -> [RecordSample] {
        var records: [RecordSample] = []
        var previous: (timestamp: Date, distance: Double)?
        var offset: TimeInterval = 0
        let total = data.endDate.timeIntervalSince(data.startDate)

        while offset <= total {
            let timestamp = data.startDate.addingTimeInterval(offset)
            offset += options.recordInterval

            if data.pauses.contains(where: { $0.contains(timestamp) && $0.end > timestamp }) {
                previous = nil
                continue
            }

            let distance = timeline.distance(at: timestamp)
            let point = timeline.route(at: timestamp)
            var speed = timeline.speed.value(at: timestamp) ?? point?.speed
            if speed == nil, let previous, let distance {
                let seconds = timestamp.timeIntervalSince(previous.timestamp)
                if seconds > 0 {
                    speed = max(0, (distance - previous.distance) / seconds)
                }
            }

            records.append(
                RecordSample(
                    timestamp: timestamp,
                    distance: distance,
                    speed: speed,
                    point: point,
                    heartRate: timeline.heartRate.value(at: timestamp),
                    cadence: timeline.cadence.value(at: timestamp),
                    power: timeline.power.value(at: timestamp),
                    temperature: timeline.temperature.value(at: timestamp),
                    verticalOscillation: timeline.verticalOscillation.value(at: timestamp),
                    groundContactTime: timeline.groundContactTime.value(at: timestamp),
                    strideLength: timeline.strideLength.value(at: timestamp)
                )
            )

            if let distance {
                previous = (timestamp, distance)
            }
        }

        return records
    }

    struct Lap: Equatable {
        let interval: DateInterval
        let records: [RecordSample]
        let trigger: FITProfile.LapTrigger
        let intensity: LapIntensity
        let name: String?
        let goal: LapGoal?

        let stepIndex: Int?
    }

    struct NormalizedLap: Equatable {
        let lap: WorkoutLap
        let isFiller: Bool
    }

    static let lapGapTolerance: TimeInterval = 2

    func buildLaps(_ data: WorkoutExportData, records: [RecordSample]) -> [Lap] {
        let recorded = Self.recordedLaps(data.laps, start: data.startDate, end: data.endDate)
        if !recorded.isEmpty {
            var stepIndex = 0
            return recorded.enumerated().map { index, entry in
                let isLast = index == recorded.count - 1
                defer { if !entry.isFiller { stepIndex += 1 } }
                return Lap(
                    interval: entry.lap.interval,
                    records: records.filter { entry.lap.interval.contains($0.timestamp) },
                    trigger: isLast ? .sessionEnd : .manual,
                    intensity: entry.lap.intensity,
                    name: entry.lap.name,
                    goal: entry.lap.goal,
                    stepIndex: entry.isFiller ? nil : stepIndex
                )
            }
        }

        var intervals = kilometerIntervals(records: records, end: data.endDate)
        var trigger = FITProfile.LapTrigger.distance
        if intervals.isEmpty {
            intervals = [DateInterval(start: data.startDate, end: data.endDate)]
            trigger = .sessionEnd
        }
        return intervals.enumerated().map { index, interval in
            Lap(
                interval: interval,
                records: records.filter { interval.contains($0.timestamp) },
                trigger: index == intervals.count - 1 ? .sessionEnd : trigger,
                intensity: .active,
                name: nil,
                goal: nil,
                stepIndex: nil
            )
        }
    }

    static func recordedLaps(_ laps: [WorkoutLap], start: Date, end: Date) -> [NormalizedLap] {
        var result: [NormalizedLap] = []
        var cursor = start

        for lap in laps.sorted(by: { $0.interval.start < $1.interval.start }) {
            var lapStart = max(lap.interval.start, cursor)
            let lapEnd = min(lap.interval.end, end)
            guard lapEnd > lapStart else { continue }
            if lapStart.timeIntervalSince(cursor) > lapGapTolerance {
                result.append(NormalizedLap(lap: WorkoutLap(start: cursor, end: lapStart), isFiller: true))
            } else {
                lapStart = cursor
            }
            result.append(
                NormalizedLap(
                    lap: WorkoutLap(
                        start: lapStart, end: lapEnd, intensity: lap.intensity, name: lap.name, goal: lap.goal),
                    isFiller: false))
            cursor = lapEnd
        }

        guard !result.isEmpty else { return [] }
        if end.timeIntervalSince(cursor) > lapGapTolerance {
            result.append(NormalizedLap(lap: WorkoutLap(start: cursor, end: end), isFiller: true))
        } else if let last = result.last, end > last.lap.interval.end {
            let extended = WorkoutLap(
                start: last.lap.interval.start, end: end, intensity: last.lap.intensity, name: last.lap.name,
                goal: last.lap.goal)
            result[result.count - 1] = NormalizedLap(lap: extended, isFiller: last.isFiller)
        }
        return result
    }

    static func stepNames(for laps: [Lap]) -> [Int: String] {
        var names: [Int: String] = [:]
        var counters: [String: Int] = [:]
        for lap in laps {
            guard let stepIndex = lap.stepIndex else { continue }
            if let name = lap.name {
                names[stepIndex] = name
                continue
            }
            switch lap.intensity {
            case .warmup:
                names[stepIndex] = AppLanguage.text("Riscaldamento")
            case .cooldown:
                names[stepIndex] = AppLanguage.text("Defaticamento")
            case .active, .recovery, .rest:
                let base =
                    lap.intensity == .recovery
                    ? AppLanguage.text("Recupero")
                    : lap.intensity == .rest
                        ? AppLanguage.text("Transizione")
                        : lap.goal == nil ? AppLanguage.text("Segmento") : AppLanguage.text("Lavoro")
                counters[base, default: 0] += 1
                names[stepIndex] = "\(base) \(counters[base]!)"
            }
        }
        return names
    }

    private func kilometerIntervals(records: [RecordSample], end: Date) -> [DateInterval] {
        guard let first = records.first else { return [] }
        var intervals: [DateInterval] = []
        var lapStart = first.timestamp
        var nextKilometer = 1.0

        for record in records {
            guard let distance = record.distance else { continue }
            while distance >= nextKilometer * 1_000 {
                if record.timestamp > lapStart {
                    intervals.append(DateInterval(start: lapStart, end: record.timestamp))
                    lapStart = record.timestamp
                }
                nextKilometer += 1
            }
        }

        if end > lapStart, let lastDistance = records.last?.distance,
            lastDistance - Double(intervals.count) * 1_000 > 1 || intervals.isEmpty
        {
            intervals.append(DateInterval(start: lapStart, end: end))
        }
        return intervals
    }

    private func writeHeader(_ writer: inout FITFileWriter, data: WorkoutExportData) {
        let productName = data.deviceModel ?? data.deviceName ?? "Apple Watch"
        writer.write(
            FITProfile.fileID,
            values: [
                0: .integer(4),
                1: .integer(Self.manufacturerDevelopment),
                2: .integer(1),
                3: .integer(Self.serialNumber(for: data.id)),
                4: .integer(FITProfile.timestamp(data.startDate)),
                8: .string("FitnessExport"),
            ])
        writer.write(
            FITProfile.fileCreator,
            values: [
                0: .integer(100),
                1: .integer(1),
            ])
        writer.write(
            FITProfile.deviceInfo,
            values: [
                253: .integer(FITProfile.timestamp(data.startDate)),
                0: .integer(0),
                2: .integer(Self.manufacturerDevelopment),
                4: .integer(1),
                25: .integer(5),
                27: .string(productName),
            ])
    }

    private func writeWorkoutSteps(_ writer: inout FITFileWriter, laps: [Lap], data: WorkoutExportData) {
        let steps = laps.filter { $0.stepIndex != nil }
        guard !steps.isEmpty else { return }
        let names = Self.stepNames(for: laps)

        writer.write(
            FITProfile.workout,
            values: [
                4: .integer(Self.fitSport(data.activityType).rawValue),
                6: .integer(Int64(steps.count)),
                8: .string(data.workoutName ?? "Apple Watch"),
                11: .integer(Self.fitSubSport(data).rawValue),
            ])

        for lap in steps {
            guard let stepIndex = lap.stepIndex else { continue }
            var values: [UInt8: FITFieldValue] = [
                254: .integer(Int64(stepIndex)),
                0: .string(names[stepIndex] ?? ""),
                3: .integer(FITProfile.WorkoutStepTarget.open.rawValue),
                7: .integer(Self.fitIntensity(lap.intensity).rawValue),
            ]
            switch lap.goal {
            case .time(let seconds)?:
                values[1] = .integer(FITProfile.WorkoutStepDuration.time.rawValue)
                values[2] = .integer(scaled(seconds, by: 1_000))
            case .distance(let meters)?:
                values[1] = .integer(FITProfile.WorkoutStepDuration.distance.rawValue)
                values[2] = .integer(scaled(meters, by: 100))
            case .open?, nil:
                values[1] = .integer(FITProfile.WorkoutStepDuration.open.rawValue)
            }
            writer.write(FITProfile.workoutStep, values: values)
        }
    }

    private func writeTimerEventsAndRecords(
        _ writer: inout FITFileWriter, data: WorkoutExportData, records: [RecordSample]
    ) {
        var events: [(Date, FITProfile.EventType)] = [(data.startDate, .start)]
        for pause in data.pauses.sorted(by: { $0.start < $1.start }) {
            events.append((pause.start, .stopAll))
            events.append((pause.end, .start))
        }
        events.append((data.endDate, .stopAll))

        var eventIndex = 0
        for record in records {
            while eventIndex < events.count, events[eventIndex].0 <= record.timestamp {
                writeEvent(&writer, at: events[eventIndex].0, type: events[eventIndex].1)
                eventIndex += 1
            }
            writeRecord(&writer, record: record, activityType: data.activityType)
        }
        while eventIndex < events.count {
            writeEvent(&writer, at: events[eventIndex].0, type: events[eventIndex].1)
            eventIndex += 1
        }
    }

    private func writeEvent(_ writer: inout FITFileWriter, at date: Date, type: FITProfile.EventType) {
        writer.write(
            FITProfile.event,
            values: [
                253: .integer(FITProfile.timestamp(date)),
                0: .integer(FITProfile.Event.timer.rawValue),
                1: .integer(type.rawValue),
                4: .integer(0),
            ])
    }

    private func writeRecord(_ writer: inout FITFileWriter, record: RecordSample, activityType: WorkoutActivityType) {
        var values: [UInt8: FITFieldValue] = [253: .integer(FITProfile.timestamp(record.timestamp))]

        if let point = record.point {
            values[0] = .integer(FITProfile.semicircles(point.latitude))
            values[1] = .integer(FITProfile.semicircles(point.longitude))
            if let altitude = point.altitude {
                values[78] = .integer(scaled(altitude + 500, by: 5))
            }
        }
        if let distance = record.distance { values[5] = .integer(scaled(distance, by: 100)) }
        if let speed = record.speed { values[73] = .integer(scaled(speed, by: 1_000)) }
        if let heartRate = record.heartRate { values[3] = .integer(Int64(heartRate.rounded())) }
        if let cadence = record.cadence {
            let fitCadence = Self.fitCadence(cadence, activityType: activityType)
            values[4] = .integer(fitCadence.whole)
            values[53] = .integer(fitCadence.fractional)
        }
        if let power = record.power { values[7] = .integer(Int64(power.rounded())) }
        if let temperature = record.temperature { values[13] = .integer(Int64(temperature.rounded())) }
        if let oscillation = record.verticalOscillation { values[39] = .integer(scaled(oscillation * 1_000, by: 10)) }
        if let contact = record.groundContactTime { values[41] = .integer(scaled(contact * 1_000, by: 10)) }
        if let stride = record.strideLength {
            values[85] = .integer(scaled(stride * 1_000, by: 10))
            if let oscillation = record.verticalOscillation, stride > 0 {
                values[83] = .integer(scaled(oscillation / stride * 100, by: 100))
            }
        }

        writer.write(FITProfile.record, values: values)
    }

    private func writeLengths(_ writer: inout FITFileWriter, data: WorkoutExportData) {
        for (index, length) in data.swimLengths.enumerated() {
            let duration = max(length.endDate.timeIntervalSince(length.startDate), 1)
            var values: [UInt8: FITFieldValue] = [
                253: .integer(FITProfile.timestamp(length.endDate)),
                254: .integer(Int64(index)),
                0: .integer(FITProfile.Event.timer.rawValue),
                1: .integer(FITProfile.EventType.stop.rawValue),
                2: .integer(FITProfile.timestamp(length.startDate)),
                3: .integer(scaled(duration, by: 1_000)),
                4: .integer(scaled(duration, by: 1_000)),
                5: .integer(Int64(length.strokeCount.rounded())),
                7: .integer(Self.fitStroke(length.style).rawValue),
                9: .integer(Int64((length.strokeCount / (duration / 60)).rounded())),
                12: .integer(1),
            ]
            if let poolLength = data.poolLengthMeters, poolLength > 0 {
                values[6] = .integer(scaled(poolLength / duration, by: 1_000))
            }
            writer.write(FITProfile.length, values: values)
        }
    }

    private func writeLap(_ writer: inout FITFileWriter, lap: Lap, index: Int, data: WorkoutExportData) {
        let stats = Statistics(records: lap.records, activityType: data.activityType)
        let pausedTime = pausedSeconds(in: lap.interval, pauses: data.pauses)
        let timerTime = max(lap.interval.duration - pausedTime, 0)

        var values: [UInt8: FITFieldValue] = [
            253: .integer(FITProfile.timestamp(lap.interval.end)),
            254: .integer(Int64(index)),
            0: .integer(FITProfile.Event.lap.rawValue),
            1: .integer(FITProfile.EventType.stop.rawValue),
            2: .integer(FITProfile.timestamp(lap.interval.start)),
            7: .integer(scaled(lap.interval.duration, by: 1_000)),
            8: .integer(scaled(timerTime, by: 1_000)),
            23: .integer(Self.fitIntensity(lap.intensity).rawValue),
            24: .integer(lap.trigger.rawValue),
            25: .integer(Self.fitSport(data.activityType).rawValue),
        ]
        if let stepIndex = lap.stepIndex { values[71] = .integer(Int64(stepIndex)) }
        if let stride = stats.avgStrideLength { values[120] = .integer(scaled(stride * 1_000, by: 10)) }

        if let distance = stats.distance {
            values[9] = .integer(scaled(distance, by: 100))
            if timerTime > 0 {
                values[13] = .integer(scaled(distance / timerTime, by: 1_000))
            }
        }
        let calories = Timeline.cumulative(data.energySegments, in: lap.interval)
        if calories > 0 { values[11] = .integer(Int64(calories.rounded())) }
        if let maxSpeed = stats.maxSpeed { values[14] = .integer(scaled(maxSpeed, by: 1_000)) }
        if let start = stats.firstPoint {
            values[3] = .integer(FITProfile.semicircles(start.latitude))
            values[4] = .integer(FITProfile.semicircles(start.longitude))
        }
        if let end = stats.lastPoint {
            values[5] = .integer(FITProfile.semicircles(end.latitude))
            values[6] = .integer(FITProfile.semicircles(end.longitude))
        }
        if let avg = stats.avgHeartRate { values[15] = .integer(Int64(avg.rounded())) }
        if let max = stats.maxHeartRate { values[16] = .integer(Int64(max.rounded())) }
        if let avg = stats.avgCadence { values[17] = .integer(avg) }
        if let max = stats.maxCadence { values[18] = .integer(max) }
        if let avg = stats.avgPower { values[19] = .integer(Int64(avg.rounded())) }
        if let max = stats.maxPower { values[20] = .integer(Int64(max.rounded())) }
        values[21] = .integer(Int64(stats.ascent.rounded()))
        values[22] = .integer(Int64(stats.descent.rounded()))
        if let temperature = stats.avgTemperature { values[50] = .integer(Int64(temperature.rounded())) }

        writer.write(FITProfile.lap, values: values)
    }

    private func writeSession(
        _ writer: inout FITFileWriter, data: WorkoutExportData, records: [RecordSample], laps: [Lap]
    ) {
        let stats = Statistics(records: records, activityType: data.activityType)
        let elapsed = data.endDate.timeIntervalSince(data.startDate)
        let timerTime =
            data.duration > 0
            ? data.duration
            : max(
                elapsed
                    - pausedSeconds(in: DateInterval(start: data.startDate, end: data.endDate), pauses: data.pauses), 0)
        let distance = data.totalDistanceMeters ?? stats.distance

        var values: [UInt8: FITFieldValue] = [
            253: .integer(FITProfile.timestamp(data.endDate)),
            254: .integer(0),
            0: .integer(FITProfile.Event.session.rawValue),
            1: .integer(FITProfile.EventType.stop.rawValue),
            2: .integer(FITProfile.timestamp(data.startDate)),
            5: .integer(Self.fitSport(data.activityType).rawValue),
            6: .integer(Self.fitSubSport(data).rawValue),
            7: .integer(scaled(elapsed, by: 1_000)),
            8: .integer(scaled(timerTime, by: 1_000)),
            25: .integer(0),
            26: .integer(Int64(laps.count)),
            28: .integer(0),
        ]

        if let distance {
            values[9] = .integer(scaled(distance, by: 100))
            if timerTime > 0 {
                values[14] = .integer(scaled(distance / timerTime, by: 1_000))
            }
        }
        if let calories = data.activeEnergyKilocalories { values[11] = .integer(Int64(calories.rounded())) }
        if let maxSpeed = stats.maxSpeed { values[15] = .integer(scaled(maxSpeed, by: 1_000)) }
        if let start = stats.firstPoint {
            values[3] = .integer(FITProfile.semicircles(start.latitude))
            values[4] = .integer(FITProfile.semicircles(start.longitude))
        }
        if let end = stats.lastPoint {
            values[38] = .integer(FITProfile.semicircles(end.latitude))
            values[39] = .integer(FITProfile.semicircles(end.longitude))
        }
        if let bounds = stats.bounds {
            values[29] = .integer(FITProfile.semicircles(bounds.maxLatitude))
            values[30] = .integer(FITProfile.semicircles(bounds.maxLongitude))
            values[31] = .integer(FITProfile.semicircles(bounds.minLatitude))
            values[32] = .integer(FITProfile.semicircles(bounds.minLongitude))
        }
        if let avg = stats.avgHeartRate { values[16] = .integer(Int64(avg.rounded())) }
        if let max = stats.maxHeartRate { values[17] = .integer(Int64(max.rounded())) }
        if let avg = stats.avgCadence { values[18] = .integer(avg) }
        if let max = stats.maxCadence { values[19] = .integer(max) }
        if let avg = stats.avgPower { values[20] = .integer(Int64(avg.rounded())) }
        if let max = stats.maxPower { values[21] = .integer(Int64(max.rounded())) }
        values[22] = .integer(Int64((data.elevationAscendedMeters ?? stats.ascent).rounded()))
        values[23] = .integer(Int64((data.elevationDescendedMeters ?? stats.descent).rounded()))
        if let temperature = stats.avgTemperature ?? data.weatherTemperatureCelsius {
            values[57] = .integer(Int64(temperature.rounded()))
        }
        if let oscillation = stats.avgVerticalOscillation { values[89] = .integer(scaled(oscillation * 1_000, by: 10)) }
        if let contact = stats.avgGroundContactTime { values[91] = .integer(scaled(contact * 1_000, by: 10)) }
        if let stride = stats.avgStrideLength { values[134] = .integer(scaled(stride * 1_000, by: 10)) }

        if !data.swimLengths.isEmpty {
            values[33] = .integer(Int64(data.swimLengths.count))
            values[10] = .integer(Int64(data.swimLengths.reduce(0) { $0 + $1.strokeCount }.rounded()))
        }
        if let poolLength = data.poolLengthMeters, poolLength > 0 {
            values[44] = .integer(scaled(poolLength, by: 100))
            values[46] = .integer(0)
        }

        writer.write(FITProfile.session, values: values)
    }

    private func writeActivity(_ writer: inout FITFileWriter, data: WorkoutExportData) {
        let timerTime = data.duration > 0 ? data.duration : data.endDate.timeIntervalSince(data.startDate)

        let timeZone = data.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? options.timeZone
        let offset = Int64(timeZone.secondsFromGMT(for: data.endDate))
        writer.write(
            FITProfile.activity,
            values: [
                253: .integer(FITProfile.timestamp(data.endDate)),
                0: .integer(scaled(timerTime, by: 1_000)),
                1: .integer(1),
                2: .integer(0),
                3: .integer(FITProfile.Event.activity.rawValue),
                4: .integer(FITProfile.EventType.stop.rawValue),
                5: .integer(FITProfile.timestamp(data.endDate) + offset),
            ])
    }

    static func serialNumber(for id: UUID) -> Int64 {
        let bytes = id.uuid
        let value = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
        return Int64(max(value, 1))
    }

    private func scaled(_ value: Double, by scale: Double) -> Int64 {
        Int64((value * scale).rounded())
    }

    private func pausedSeconds(in interval: DateInterval, pauses: [DateInterval]) -> TimeInterval {
        pauses.reduce(0) { $0 + (interval.intersection(with: $1)?.duration ?? 0) }
    }

    static func fitCadence(_ value: Double, activityType: WorkoutActivityType) -> (whole: Int64, fractional: Int64) {
        let rpm = activityType == .cycling ? value : value / 2
        let whole = rpm.rounded(.down)
        return (Int64(whole), Int64(((rpm - whole) * 128).rounded()))
    }

    static func fitSport(_ activityType: WorkoutActivityType) -> FITProfile.Sport {
        switch activityType {
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .hiking: return .hiking
        case .swimming: return .swimming
        case .other: return .generic
        }
    }

    static func fitIntensity(_ intensity: LapIntensity) -> FITProfile.Intensity {
        switch intensity {
        case .active: return .active
        case .rest: return .rest
        case .warmup: return .warmup
        case .cooldown: return .cooldown
        case .recovery: return .recovery
        }
    }

    static func fitSubSport(_ data: WorkoutExportData) -> FITProfile.SubSport {
        switch data.activityType {
        case .running where data.isIndoor: return .treadmill
        case .cycling where data.isIndoor: return .indoorCycling
        case .swimming: return data.poolLengthMeters != nil ? .lapSwimming : .openWater
        default: return .generic
        }
    }

    static func fitStroke(_ style: SwimStrokeStyle) -> FITProfile.SwimStroke {
        switch style {
        case .freestyle: return .freestyle
        case .backstroke: return .backstroke
        case .breaststroke: return .breaststroke
        case .butterfly: return .butterfly
        case .kickboard: return .drill
        case .mixed, .unknown: return .mixed
        }
    }

    struct Statistics {
        let distance: Double?
        let maxSpeed: Double?
        let firstPoint: RoutePoint?
        let lastPoint: RoutePoint?
        let avgHeartRate: Double?
        let maxHeartRate: Double?
        let avgCadence: Int64?
        let maxCadence: Int64?
        let avgPower: Double?
        let maxPower: Double?
        let avgTemperature: Double?
        let avgVerticalOscillation: Double?
        let avgGroundContactTime: Double?
        let avgStrideLength: Double?
        let ascent: Double
        let descent: Double

        let bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double)?

        init(records: [RecordSample], activityType: WorkoutActivityType) {
            let distances = records.compactMap(\.distance)
            distance = distances.count >= 2 ? distances.last! - distances.first! : nil
            maxSpeed = records.compactMap(\.speed).max()
            firstPoint = records.first(where: { $0.point != nil })?.point
            lastPoint = records.last(where: { $0.point != nil })?.point

            let heartRates = records.compactMap(\.heartRate)
            avgHeartRate = Statistics.mean(heartRates)
            maxHeartRate = heartRates.max()

            let cadences = records.compactMap(\.cadence)
            avgCadence = Statistics.mean(cadences).map {
                FITActivityEncoder.fitCadence($0, activityType: activityType).whole
            }
            maxCadence = cadences.max().map { FITActivityEncoder.fitCadence($0, activityType: activityType).whole }

            let powers = records.compactMap(\.power)
            avgPower = Statistics.mean(powers)
            maxPower = powers.max()
            avgTemperature = Statistics.mean(records.compactMap(\.temperature))
            avgVerticalOscillation = Statistics.mean(records.compactMap(\.verticalOscillation))
            avgGroundContactTime = Statistics.mean(records.compactMap(\.groundContactTime))
            avgStrideLength = Statistics.mean(records.compactMap(\.strideLength))

            let points = records.compactMap(\.point)
            if let minLatitude = points.map(\.latitude).min(), let maxLatitude = points.map(\.latitude).max(),
                let minLongitude = points.map(\.longitude).min(), let maxLongitude = points.map(\.longitude).max()
            {
                bounds = (minLatitude, maxLatitude, minLongitude, maxLongitude)
            } else {
                bounds = nil
            }

            let elevation = Statistics.elevationGain(records.compactMap { $0.point?.altitude })
            ascent = elevation.ascent
            descent = elevation.descent
        }

        private static func mean(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        static func elevationGain(_ altitudes: [Double], threshold: Double = 3) -> (ascent: Double, descent: Double) {
            guard var reference = altitudes.first else { return (0, 0) }
            var ascent = 0.0
            var descent = 0.0
            for altitude in altitudes.dropFirst() {
                let delta = altitude - reference
                if delta >= threshold {
                    ascent += delta
                    reference = altitude
                } else if delta <= -threshold {
                    descent -= delta
                    reference = altitude
                }
            }
            return (ascent, descent)
        }
    }

    struct Timeline {
        let heartRate: HoldSeries
        let cadence: HoldSeries
        let power: HoldSeries
        let speed: HoldSeries
        let temperature: HoldSeries
        let verticalOscillation: HoldSeries
        let groundContactTime: HoldSeries
        let strideLength: HoldSeries
        private let distanceSegments: [DistanceSampleSegment]
        private let distancePrefix: [Double]
        private let routePoints: [RoutePoint]
        private let fallbackDistance: (start: Date, end: Date, total: Double)?

        init(data: WorkoutExportData, holdWindow: TimeInterval) {
            heartRate = HoldSeries(data.heartRateSamples, holdWindow: holdWindow)
            cadence = HoldSeries(data.cadenceSamples, holdWindow: holdWindow)
            power = HoldSeries(data.powerSamples, holdWindow: holdWindow)
            speed = HoldSeries(data.speedSamples, holdWindow: 10)
            temperature = HoldSeries(data.temperatureSamples, holdWindow: 600)
            verticalOscillation = HoldSeries(data.verticalOscillationSamples, holdWindow: holdWindow)
            groundContactTime = HoldSeries(data.groundContactTimeSamples, holdWindow: holdWindow)
            strideLength = HoldSeries(data.strideLengthSamples, holdWindow: holdWindow)

            distanceSegments = data.distanceSegments.filter { $0.meters >= 0 }.sorted { $0.startDate < $1.startDate }
            var prefix: [Double] = []
            var running = 0.0
            for segment in distanceSegments {
                prefix.append(running)
                running += segment.meters
            }
            distancePrefix = prefix
            routePoints = data.routePoints.sorted { $0.timestamp < $1.timestamp }

            if distanceSegments.isEmpty, let total = data.totalDistanceMeters, total > 0 {
                fallbackDistance = (data.startDate, data.endDate, total)
            } else {
                fallbackDistance = nil
            }
        }

        func distance(at date: Date) -> Double? {
            if let fallbackDistance {
                let span = fallbackDistance.end.timeIntervalSince(fallbackDistance.start)
                guard span > 0 else { return nil }
                let progress = min(max(date.timeIntervalSince(fallbackDistance.start) / span, 0), 1)
                return fallbackDistance.total * progress
            }
            guard !distanceSegments.isEmpty else { return nil }

            var low = 0
            var high = distanceSegments.count
            while low < high {
                let mid = (low + high) / 2
                if distanceSegments[mid].startDate <= date { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return 0 }
            let index = low - 1
            let segment = distanceSegments[index]
            let duration = segment.endDate.timeIntervalSince(segment.startDate)
            guard duration > 0, date < segment.endDate else {
                return distancePrefix[index] + segment.meters
            }
            let progress = date.timeIntervalSince(segment.startDate) / duration
            return distancePrefix[index] + segment.meters * progress
        }

        func route(at date: Date, tolerance: TimeInterval = 10) -> RoutePoint? {
            guard !routePoints.isEmpty else { return nil }
            var low = 0
            var high = routePoints.count
            while low < high {
                let mid = (low + high) / 2
                if routePoints[mid].timestamp <= date { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return nil }
            let point = routePoints[low - 1]
            return date.timeIntervalSince(point.timestamp) <= tolerance ? point : nil
        }

        static func cumulative(_ segments: [DistanceSampleSegment], in interval: DateInterval) -> Double {
            segments.reduce(0) { total, segment in
                let segmentInterval = DateInterval(
                    start: segment.startDate, end: max(segment.endDate, segment.startDate))
                guard segmentInterval.duration > 0 else {
                    return interval.contains(segment.startDate) ? total + segment.meters : total
                }
                guard let overlap = interval.intersection(with: segmentInterval), overlap.duration > 0 else {
                    return total
                }
                return total + segment.meters * (overlap.duration / segmentInterval.duration)
            }
        }
    }

    struct HoldSeries {
        private let samples: [TimedValueSample]
        private let holdWindow: TimeInterval

        init(_ samples: [TimedValueSample], holdWindow: TimeInterval) {
            self.samples = samples.sorted { $0.startDate < $1.startDate }
            self.holdWindow = holdWindow
        }

        func value(at date: Date) -> Double? {
            guard !samples.isEmpty else { return nil }
            var low = 0
            var high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].startDate <= date { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return nil }
            let sample = samples[low - 1]
            let expiry = max(sample.endDate, sample.startDate.addingTimeInterval(holdWindow))
            return date <= expiry ? sample.value : nil
        }
    }
}
