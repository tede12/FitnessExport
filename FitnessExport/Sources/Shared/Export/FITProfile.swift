import Foundation

enum FITProfile {

    static let epochOffset: TimeInterval = 631_065_600

    static func timestamp(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - epochOffset).rounded())
    }

    static func semicircles(_ degrees: Double) -> Int64 {
        Int64((degrees * (Double(1 << 31) / 180)).rounded())
    }

    enum Sport: Int64 {
        case generic = 0
        case running = 1
        case cycling = 2
        case swimming = 5
        case walking = 11
        case hiking = 17
    }

    enum SubSport: Int64 {
        case generic = 0
        case treadmill = 1
        case indoorCycling = 6
        case lapSwimming = 17
        case openWater = 18
    }

    enum Event: Int64 {
        case timer = 0
        case session = 8
        case lap = 9
        case activity = 26
    }

    enum EventType: Int64 {
        case start = 0
        case stop = 1
        case stopAll = 4
    }

    enum LapTrigger: Int64 {
        case manual = 0
        case distance = 2
        case sessionEnd = 7
    }

    enum Intensity: Int64 {
        case active = 0
        case rest = 1
        case warmup = 2
        case cooldown = 3
        case recovery = 4
    }

    enum WorkoutStepDuration: Int64 {
        case time = 0
        case distance = 1
        case open = 5
    }

    enum WorkoutStepTarget: Int64 {
        case open = 2
    }

    enum SwimStroke: Int64 {
        case freestyle = 0
        case backstroke = 1
        case breaststroke = 2
        case butterfly = 3
        case drill = 4
        case mixed = 5
    }

    static let fileID = FITMessageDefinition(
        globalNumber: 0, localType: 0,
        fields: [
            .init(0, .enum),
            .init(1, .uint16),
            .init(2, .uint16),
            .init(3, .uint32z),
            .init(4, .uint32),
            .init(8, .string, size: 32),
        ])

    static let fileCreator = FITMessageDefinition(
        globalNumber: 49, localType: 1,
        fields: [
            .init(0, .uint16),
            .init(1, .uint8),
        ])

    static let deviceInfo = FITMessageDefinition(
        globalNumber: 23, localType: 2,
        fields: [
            .init(253, .uint32),
            .init(0, .uint8),
            .init(2, .uint16),
            .init(4, .uint16),
            .init(25, .enum),
            .init(27, .string, size: 32),
        ])

    static let event = FITMessageDefinition(
        globalNumber: 21, localType: 3,
        fields: [
            .init(253, .uint32),
            .init(0, .enum),
            .init(1, .enum),
            .init(4, .uint8),
        ])

    static let record = FITMessageDefinition(
        globalNumber: 20, localType: 4,
        fields: [
            .init(253, .uint32),
            .init(0, .sint32),
            .init(1, .sint32),
            .init(5, .uint32),
            .init(73, .uint32),
            .init(78, .uint32),
            .init(3, .uint8),
            .init(4, .uint8),
            .init(53, .uint8),
            .init(7, .uint16),
            .init(13, .sint8),
            .init(39, .uint16),
            .init(41, .uint16),
            .init(85, .uint16),
            .init(83, .uint16),
        ])

    static let lap = FITMessageDefinition(
        globalNumber: 19, localType: 5,
        fields: [
            .init(253, .uint32),
            .init(254, .uint16),
            .init(0, .enum),
            .init(1, .enum),
            .init(2, .uint32),
            .init(3, .sint32),
            .init(4, .sint32),
            .init(5, .sint32),
            .init(6, .sint32),
            .init(7, .uint32),
            .init(8, .uint32),
            .init(9, .uint32),
            .init(11, .uint16),
            .init(13, .uint16),
            .init(14, .uint16),
            .init(15, .uint8),
            .init(16, .uint8),
            .init(17, .uint8),
            .init(18, .uint8),
            .init(19, .uint16),
            .init(20, .uint16),
            .init(21, .uint16),
            .init(22, .uint16),
            .init(23, .enum),
            .init(24, .enum),
            .init(25, .enum),
            .init(50, .sint8),
            .init(71, .uint16),
            .init(120, .uint16),
        ])

    static let length = FITMessageDefinition(
        globalNumber: 101, localType: 6,
        fields: [
            .init(253, .uint32),
            .init(254, .uint16),
            .init(0, .enum),
            .init(1, .enum),
            .init(2, .uint32),
            .init(3, .uint32),
            .init(4, .uint32),
            .init(5, .uint16),
            .init(6, .uint16),
            .init(7, .enum),
            .init(9, .uint8),
            .init(12, .enum),
        ])

    static let session = FITMessageDefinition(
        globalNumber: 18, localType: 7,
        fields: [
            .init(253, .uint32),
            .init(254, .uint16),
            .init(0, .enum),
            .init(1, .enum),
            .init(2, .uint32),
            .init(3, .sint32),
            .init(4, .sint32),
            .init(5, .enum),
            .init(6, .enum),
            .init(7, .uint32),
            .init(8, .uint32),
            .init(9, .uint32),
            .init(10, .uint32),
            .init(11, .uint16),
            .init(14, .uint16),
            .init(15, .uint16),
            .init(16, .uint8),
            .init(17, .uint8),
            .init(18, .uint8),
            .init(19, .uint8),
            .init(20, .uint16),
            .init(21, .uint16),
            .init(22, .uint16),
            .init(23, .uint16),
            .init(25, .uint16),
            .init(26, .uint16),
            .init(28, .enum),
            .init(29, .sint32),
            .init(30, .sint32),
            .init(31, .sint32),
            .init(32, .sint32),
            .init(38, .sint32),
            .init(39, .sint32),
            .init(33, .uint16),
            .init(44, .uint16),
            .init(46, .enum),
            .init(57, .sint8),
            .init(89, .uint16),
            .init(91, .uint16),
            .init(134, .uint16),
        ])

    static let workout = FITMessageDefinition(
        globalNumber: 26, localType: 9,
        fields: [
            .init(4, .enum),
            .init(6, .uint16),
            .init(8, .string, size: 32),
            .init(11, .enum),
        ])

    static let workoutStep = FITMessageDefinition(
        globalNumber: 27, localType: 10,
        fields: [
            .init(254, .uint16),
            .init(0, .string, size: 32),
            .init(1, .enum),
            .init(2, .uint32),
            .init(3, .enum),
            .init(7, .enum),
        ])

    static let activity = FITMessageDefinition(
        globalNumber: 34, localType: 8,
        fields: [
            .init(253, .uint32),
            .init(0, .uint32),
            .init(1, .uint16),
            .init(2, .enum),
            .init(3, .enum),
            .init(4, .enum),
            .init(5, .uint32),
        ])
}
