import Foundation
import XCTest

@testable import FitnessExport

final class FITEncodingTests: ItalianLocalizationTestCase {
    private let start = Date(timeIntervalSince1970: 1_773_298_500)

    func testCRCMatchesReferenceVector() {

        let header = Data([0x0E, 0x10, 0x8C, 0x08, 0x00, 0x00, 0x00, 0x00, 0x2E, 0x46, 0x49, 0x54])
        XCTAssertEqual(FITCRC.compute(Data()), 0)
        XCTAssertEqual(FITCRC.compute(header), 0x92C3)
    }

    func testFileLayoutHeaderAndTrailingCRC() {
        var writer = FITFileWriter()
        writer.write(FITProfile.fileCreator, values: [0: .integer(100), 1: .integer(1)])
        let file = writer.finish()

        XCTAssertEqual(file[0], 14)
        XCTAssertEqual(String(bytes: file[8..<12], encoding: .ascii), ".FIT")
        let dataSize = Int(file[4]) | Int(file[5]) << 8 | Int(file[6]) << 16 | Int(file[7]) << 24
        XCTAssertEqual(dataSize, file.count - 14 - 2)

        XCTAssertEqual(dataSize, 12 + 4)
        XCTAssertEqual(FITCRC.compute(file), 0, "il CRC finale deve azzerare il checksum dell'intero file")
    }

    func testMissingValuesAreWrittenAsInvalid() {
        var writer = FITFileWriter()
        writer.write(FITProfile.fileCreator, values: [:])
        let file = writer.finish()
        let payload = file[(14 + 12 + 1)..<(14 + 12 + 4)]
        XCTAssertEqual(Array(payload), [0xFF, 0xFF, 0xFF])
    }

    func testRunningCadenceIsHalvedWithFractionalRemainder() {
        let running = FITActivityEncoder.fitCadence(171, activityType: .running)
        XCTAssertEqual(running.whole, 85)
        XCTAssertEqual(running.fractional, 64)

        let cycling = FITActivityEncoder.fitCadence(90, activityType: .cycling)
        XCTAssertEqual(cycling.whole, 90)
        XCTAssertEqual(cycling.fractional, 0)
    }

    func testEncodedRunHasExpectedMessagesAndTotals() throws {
        let data = makeRun(
            seconds: 600, meters: 2_000, pause: DateInterval(start: start.addingTimeInterval(300), duration: 60))
        let file = FITActivityEncoder().encode(data)
        let decoded = try FITTestDecoder.decode(file)

        XCTAssertEqual(decoded.messages(0).count, 1, "file_id")
        XCTAssertEqual(decoded.messages(34).count, 1, "activity")
        XCTAssertEqual(decoded.messages(18).count, 1, "session")

        XCTAssertEqual(decoded.messages(20).count, 541, "record")

        XCTAssertEqual(decoded.messages(21).map { $0[1] }, [0, 4, 0, 4])

        let laps = decoded.messages(19)
        XCTAssertEqual(laps.count, 2)
        XCTAssertEqual(laps[0][24], 2, "lap_trigger distance")
        XCTAssertEqual(laps[1][24], 7, "lap_trigger session_end")

        let session = try XCTUnwrap(decoded.messages(18).first)
        XCTAssertEqual(session[5], 1, "sport running")
        XCTAssertEqual(session[9], 200_000, "total_distance in cm")
        XCTAssertEqual(session[8], 540_000, "total_timer_time in ms esclude la pausa")
        XCTAssertEqual(session[7], 600_000, "total_elapsed_time in ms")
        XCTAssertEqual(session[16], 150, "avg_heart_rate")
        XCTAssertEqual(session[18], 85, "avg_cadence in falcate/min")
        XCTAssertEqual(session[26], 2, "num_laps")

        let firstRecord = try XCTUnwrap(decoded.messages(20).first)
        XCTAssertEqual(firstRecord[253], FITProfile.timestamp(start))
        XCTAssertEqual(firstRecord[3], 150)
        XCTAssertEqual(firstRecord[7], 260, "power")
        XCTAssertEqual(firstRecord[0], FITProfile.semicircles(0.0))
    }

    func testRecordedLapsBecomeFITLapsWithIntensityAndWorkoutSteps() throws {

        let laps = [
            WorkoutLap(start: start, end: start.addingTimeInterval(120), intensity: .warmup, goal: .time(120)),
            WorkoutLap(
                start: start.addingTimeInterval(120), end: start.addingTimeInterval(180), intensity: .active,
                goal: .distance(200)),
            WorkoutLap(
                start: start.addingTimeInterval(180), end: start.addingTimeInterval(240), intensity: .recovery,
                goal: .time(60)),
            WorkoutLap(
                start: start.addingTimeInterval(240), end: start.addingTimeInterval(300), intensity: .active,
                name: "Sprint", goal: .distance(200)),
            WorkoutLap(
                start: start.addingTimeInterval(300), end: start.addingTimeInterval(540), intensity: .cooldown,
                goal: .open),
        ]
        let data = makeRun(seconds: 600, meters: 2_000, pause: nil, laps: laps)
        let decoded = try FITTestDecoder.decode(FITActivityEncoder().encode(data))

        let fitLaps = decoded.messages(19)
        XCTAssertEqual(fitLaps.count, 6, "5 step + il lap di riempimento finale")
        XCTAssertEqual(
            fitLaps.map { $0[23] }, [2, 0, 4, 0, 3, 0], "intensity: warmup, active, recovery, active, cooldown, active")
        XCTAssertEqual(fitLaps.map { $0[24] }, [0, 0, 0, 0, 0, 7], "lap_trigger manual, l'ultimo session_end")
        XCTAssertEqual(fitLaps.map { $0[254] }, [0, 1, 2, 3, 4, 5], "message_index progressivo")
        XCTAssertEqual(fitLaps.map { $0[71] }, [0, 1, 2, 3, 4, nil], "wkt_step_index; il riempimento non è uno step")
        XCTAssertEqual(fitLaps.map { $0[0] }, Array(repeating: 9, count: 6), "event = lap")
        XCTAssertEqual(fitLaps[1][2], FITProfile.timestamp(start.addingTimeInterval(120)), "start_time")
        XCTAssertEqual(fitLaps[1][253], FITProfile.timestamp(start.addingTimeInterval(180)), "timestamp = fine lap")
        XCTAssertEqual(fitLaps[1][7], 60_000, "total_elapsed_time in ms")

        XCTAssertEqual(fitLaps[1][9], 20_000, "total_distance in cm")
        XCTAssertEqual(fitLaps[5][2], FITProfile.timestamp(start.addingTimeInterval(540)))
        XCTAssertEqual(fitLaps[5][253], FITProfile.timestamp(start.addingTimeInterval(600)))

        XCTAssertEqual(fitLaps.compactMap { $0[7] }.reduce(0, +), 600_000)
        XCTAssertEqual(fitLaps.compactMap { $0[9] }.reduce(0, +), 200_000)

        let session = try XCTUnwrap(decoded.messages(18).first)
        XCTAssertEqual(session[26], 6, "num_laps")
        XCTAssertEqual(session[0], 8, "event = session")

        let workout = try XCTUnwrap(decoded.messages(26).first)
        XCTAssertEqual(workout[6], 5, "num_valid_steps")
        XCTAssertEqual(workout[4], 1, "sport running")

        let steps = decoded.messages(27)
        XCTAssertEqual(steps.map { $0[254] }, [0, 1, 2, 3, 4], "message_index")
        XCTAssertEqual(steps.map { $0[7] }, [2, 0, 4, 0, 3], "intensity")
        XCTAssertEqual(steps.map { $0[1] }, [0, 1, 0, 1, 5], "duration_type: time, distance, time, distance, open")
        XCTAssertEqual(
            steps.map { $0[2] }, [120_000, 20_000, 60_000, 20_000, nil], "duration_value: ms per tempo, cm per distanza"
        )
        XCTAssertEqual(steps.map { $0[3] }, Array(repeating: 2, count: 5), "target_type open")
    }

    func testKilometerSplitsHaveNoWorkoutSteps() throws {
        let decoded = try FITTestDecoder.decode(
            FITActivityEncoder().encode(makeRun(seconds: 600, meters: 2_000, pause: nil)))
        XCTAssertTrue(decoded.messages(26).isEmpty)
        XCTAssertTrue(decoded.messages(27).isEmpty)
        XCTAssertEqual(decoded.messages(19).map { $0[71] }, [nil, nil])
    }

    func testStepNamesFollowTheFitnessAppConvention() {
        func lap(_ intensity: LapIntensity, name: String? = nil, goal: LapGoal? = .open, stepIndex: Int?)
            -> FITActivityEncoder.Lap
        {
            FITActivityEncoder.Lap(
                interval: DateInterval(start: start, duration: 60), records: [], trigger: .manual, intensity: intensity,
                name: name, goal: goal, stepIndex: stepIndex)
        }
        let names = FITActivityEncoder.stepNames(for: [
            lap(.warmup, stepIndex: 0), lap(.active, stepIndex: 1), lap(.recovery, stepIndex: 2),
            lap(.active, name: "Sprint", stepIndex: 3), lap(.recovery, stepIndex: 4), lap(.cooldown, stepIndex: 5),
            lap(.active, goal: nil, stepIndex: 6), lap(.active, stepIndex: nil),
        ])
        XCTAssertEqual(
            names,
            [
                0: "Riscaldamento", 1: "Lavoro 1", 2: "Recupero 1", 3: "Sprint", 4: "Recupero 2", 5: "Defaticamento",
                6: "Segmento 1",
            ])
    }

    func testLocalTimestampUsesTheWorkoutTimeZone() throws {
        let rome = WorkoutExportData(
            id: UUID(), activityType: .running, startDate: start, endDate: start.addingTimeInterval(60), duration: 60,
            totalDistanceMeters: nil, activeEnergyKilocalories: nil, timeZoneIdentifier: "Europe/Rome")
        let tokyo = WorkoutExportData(
            id: UUID(), activityType: .running, startDate: start, endDate: start.addingTimeInterval(60), duration: 60,
            totalDistanceMeters: nil, activeEnergyKilocalories: nil, timeZoneIdentifier: "Asia/Tokyo")
        let romeActivity = try XCTUnwrap(FITTestDecoder.decode(FITActivityEncoder().encode(rome)).messages(34).first)
        let tokyoActivity = try XCTUnwrap(FITTestDecoder.decode(FITActivityEncoder().encode(tokyo)).messages(34).first)
        XCTAssertEqual(romeActivity[5]! - romeActivity[253]!, 3_600, "marzo, CET")
        XCTAssertEqual(tokyoActivity[5]! - tokyoActivity[253]!, 9 * 3_600)
    }

    func testRecordedLapsAreNormalisedToCoverTheSession() {
        let end = start.addingTimeInterval(600)
        let laps = [

            WorkoutLap(start: start.addingTimeInterval(200), end: start.addingTimeInterval(700), intensity: .cooldown),
            WorkoutLap(start: start.addingTimeInterval(1), end: start.addingTimeInterval(100), intensity: .warmup),
            WorkoutLap(start: start.addingTimeInterval(100), end: start.addingTimeInterval(190), intensity: .active),

            WorkoutLap(start: start.addingTimeInterval(120), end: start.addingTimeInterval(150), intensity: .recovery),
        ]
        let normalised = FITActivityEncoder.recordedLaps(laps, start: start, end: end)

        XCTAssertEqual(
            normalised.map(\.lap),
            [
                WorkoutLap(start: start, end: start.addingTimeInterval(100), intensity: .warmup),
                WorkoutLap(
                    start: start.addingTimeInterval(100), end: start.addingTimeInterval(190), intensity: .active),
                WorkoutLap(
                    start: start.addingTimeInterval(190), end: start.addingTimeInterval(200), intensity: .active),
                WorkoutLap(start: start.addingTimeInterval(200), end: end, intensity: .cooldown),
            ])
        XCTAssertEqual(normalised.map(\.isFiller), [false, false, true, false])
    }

    func testRecordedLapsEndingJustBeforeTheSessionAreExtended() {
        let end = start.addingTimeInterval(600)
        let laps = [
            WorkoutLap(start: start, end: start.addingTimeInterval(300)),
            WorkoutLap(
                start: start.addingTimeInterval(300), end: start.addingTimeInterval(599), intensity: .recovery,
                goal: .time(300)),
        ]
        let normalised = FITActivityEncoder.recordedLaps(laps, start: start, end: end)
        XCTAssertEqual(
            normalised.last?.lap,
            WorkoutLap(start: start.addingTimeInterval(300), end: end, intensity: .recovery, goal: .time(300)))
        XCTAssertEqual(normalised.last?.isFiller, false)
        XCTAssertTrue(FITActivityEncoder.recordedLaps([], start: start, end: end).isEmpty)
    }

    func testWorkoutWithoutSamplesStillProducesValidFile() throws {
        let data = WorkoutExportData(
            id: UUID(),
            activityType: .walking,
            startDate: start,
            endDate: start.addingTimeInterval(120),
            duration: 120,
            totalDistanceMeters: 150,
            activeEnergyKilocalories: 10
        )
        let decoded = try FITTestDecoder.decode(FITActivityEncoder().encode(data))
        XCTAssertEqual(decoded.messages(19).count, 1)
        XCTAssertEqual(decoded.messages(19)[0][24], 7)

        XCTAssertEqual(decoded.messages(20).last?[5], 15_000)
    }

    private func makeRun(seconds: Int, meters: Double, pause: DateInterval?, laps: [WorkoutLap] = [])
        -> WorkoutExportData
    {
        let metersPerSecond = meters / Double(seconds)
        return WorkoutExportData(
            id: UUID(),
            activityType: .running,
            startDate: start,
            endDate: start.addingTimeInterval(Double(seconds)),
            duration: Double(seconds) - (pause?.duration ?? 0),
            totalDistanceMeters: meters,
            activeEnergyKilocalories: 150,
            heartRateSamples: stride(from: 0, through: seconds, by: 5).map {
                TimedValueSample(
                    startDate: start.addingTimeInterval(Double($0)), endDate: start.addingTimeInterval(Double($0)),
                    value: 150)
            },
            cadenceSamples: stride(from: 0, through: seconds, by: 10).map {
                TimedValueSample(
                    startDate: start.addingTimeInterval(Double($0)), endDate: start.addingTimeInterval(Double($0 + 10)),
                    value: 170)
            },
            powerSamples: stride(from: 0, through: seconds, by: 1).map {
                TimedValueSample(
                    startDate: start.addingTimeInterval(Double($0)), endDate: start.addingTimeInterval(Double($0 + 1)),
                    value: 260)
            },
            distanceSegments: stride(from: 0, to: seconds, by: 5).map {
                DistanceSampleSegment(
                    startDate: start.addingTimeInterval(Double($0)), endDate: start.addingTimeInterval(Double($0 + 5)),
                    meters: metersPerSecond * 5)
            },
            routePoints: stride(from: 0, through: seconds, by: 1).map {
                RoutePoint(
                    timestamp: start.addingTimeInterval(Double($0)), latitude: 0.0,
                    longitude: 0.0 + Double($0) * 0.00001, altitude: 120, speed: metersPerSecond)
            },
            pauses: pause.map { [$0] } ?? [],
            laps: laps
        )
    }
}

enum FITTestDecoder {
    struct Decoded {
        var records: [(global: UInt16, fields: [UInt8: Int64])] = []

        func messages(_ global: UInt16) -> [[UInt8: Int64]] {
            records.filter { $0.global == global }.map(\.fields)
        }
    }

    struct DecodeError: Error {
        let message: String
    }

    static func decode(_ file: Data) throws -> Decoded {
        guard file.count > 16, FITCRC.compute(file) == 0 else {
            throw DecodeError(message: "CRC non valido")
        }
        let bytes = [UInt8](file)
        let headerSize = Int(bytes[0])
        let dataSize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        var cursor = headerSize
        let end = headerSize + dataSize
        var definitions: [UInt8: (global: UInt16, fields: [(number: UInt8, size: Int, baseType: UInt8)])] = [:]
        var decoded = Decoded()

        while cursor < end {
            let header = bytes[cursor]
            cursor += 1
            let localType = header & 0x0F

            if header & 0x40 != 0 {
                guard bytes[cursor + 1] == 0 else { throw DecodeError(message: "solo little-endian supportato") }
                let global = UInt16(bytes[cursor + 2]) | UInt16(bytes[cursor + 3]) << 8
                let fieldCount = Int(bytes[cursor + 4])
                cursor += 5
                var fields: [(UInt8, Int, UInt8)] = []
                for _ in 0..<fieldCount {
                    fields.append((bytes[cursor], Int(bytes[cursor + 1]), bytes[cursor + 2]))
                    cursor += 3
                }
                definitions[localType] = (global, fields)
            } else {
                guard let definition = definitions[localType] else {
                    throw DecodeError(message: "dati senza definizione per local type \(localType)")
                }
                var values: [UInt8: Int64] = [:]
                for field in definition.fields {
                    let raw = bytes[cursor..<(cursor + field.size)]
                    cursor += field.size
                    guard field.baseType != 0x07 else { continue }
                    var unsigned: UInt64 = 0
                    for (index, byte) in raw.enumerated() {
                        unsigned |= UInt64(byte) << (8 * UInt64(index))
                    }
                    let isSigned = [0x01, 0x83, 0x85].contains(field.baseType)
                    let signed: Int64
                    switch (isSigned, field.size) {
                    case (true, 1): signed = Int64(Int8(bitPattern: UInt8(unsigned)))
                    case (true, 2): signed = Int64(Int16(bitPattern: UInt16(unsigned)))
                    case (true, 4): signed = Int64(Int32(bitPattern: UInt32(unsigned)))
                    default: signed = Int64(unsigned)
                    }
                    let invalid = FITBaseType(rawValue: field.baseType)?.invalidValue
                    if invalid == nil || unsigned != invalid! {
                        values[field.number] = signed
                    }
                }
                decoded.records.append((definition.global, values))
            }
        }
        return decoded
    }
}
