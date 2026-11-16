import Foundation

enum FITBaseType: UInt8 {
    case `enum` = 0x00
    case sint8 = 0x01
    case uint8 = 0x02
    case sint16 = 0x83
    case uint16 = 0x84
    case sint32 = 0x85
    case uint32 = 0x86
    case string = 0x07
    case float32 = 0x88
    case uint8z = 0x0A
    case uint16z = 0x8B
    case uint32z = 0x8C
    case byte = 0x0D

    var size: Int {
        switch self {
        case .enum, .sint8, .uint8, .string, .uint8z, .byte:
            return 1
        case .sint16, .uint16, .uint16z:
            return 2
        case .sint32, .uint32, .float32, .uint32z:
            return 4
        }
    }

    var invalidValue: UInt64 {
        switch self {
        case .enum, .uint8, .string, .byte:
            return 0xFF
        case .sint8:
            return 0x7F
        case .sint16:
            return 0x7FFF
        case .uint16:
            return 0xFFFF
        case .sint32:
            return 0x7FFF_FFFF
        case .uint32, .float32:
            return 0xFFFF_FFFF
        case .uint8z, .uint16z, .uint32z:
            return 0
        }
    }
}

struct FITFieldDefinition: Equatable, Sendable {
    let number: UInt8
    let baseType: FITBaseType

    let size: Int

    init(_ number: UInt8, _ baseType: FITBaseType, size: Int? = nil) {
        self.number = number
        self.baseType = baseType
        self.size = size ?? baseType.size
    }
}

struct FITMessageDefinition: Equatable, Sendable {
    let globalNumber: UInt16
    let localType: UInt8
    let fields: [FITFieldDefinition]
}

enum FITFieldValue: Equatable, Sendable {
    case integer(Int64)
    case string(String)
}

enum FITCRC {
    private static let table: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func compute(_ data: Data, seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for byte in data {

            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int((byte >> 4) & 0xF)]
        }
        return crc
    }
}

struct FITFileWriter {
    static let headerSize = 14
    static let protocolVersion: UInt8 = 0x20
    static let profileVersion: UInt16 = 2196

    private var body = Data()
    private var writtenDefinitions: [UInt8: FITMessageDefinition] = [:]

    mutating func write(_ definition: FITMessageDefinition, values: [UInt8: FITFieldValue]) {
        if writtenDefinitions[definition.localType] != definition {
            writeDefinition(definition)
            writtenDefinitions[definition.localType] = definition
        }

        body.append(definition.localType & 0x0F)
        for field in definition.fields {
            append(values[field.number], as: field)
        }
    }

    func finish() -> Data {
        var header = Data(capacity: Self.headerSize)
        header.append(UInt8(Self.headerSize))
        header.append(Self.protocolVersion)
        header.append(littleEndian: Self.profileVersion)
        header.append(littleEndian: UInt32(body.count))
        header.append(contentsOf: Array(".FIT".utf8))
        header.append(littleEndian: FITCRC.compute(header))

        var file = header + body
        file.append(littleEndian: FITCRC.compute(file))
        return file
    }

    private mutating func writeDefinition(_ definition: FITMessageDefinition) {
        body.append(0x40 | (definition.localType & 0x0F))
        body.append(0x00)
        body.append(0x00)
        body.append(littleEndian: definition.globalNumber)
        body.append(UInt8(definition.fields.count))
        for field in definition.fields {
            body.append(field.number)
            body.append(UInt8(field.size))
            body.append(field.baseType.rawValue)
        }
    }

    private mutating func append(_ value: FITFieldValue?, as field: FITFieldDefinition) {
        switch (field.baseType, value) {
        case (.string, .string(let text)):
            var bytes = Array(text.utf8.prefix(field.size - 1))
            bytes.append(contentsOf: [UInt8](repeating: 0, count: field.size - bytes.count))
            body.append(contentsOf: bytes)

        case (.string, _):
            body.append(contentsOf: [UInt8](repeating: 0, count: field.size))

        case (_, .integer(let raw)):
            append(rawInteger: clamp(raw, to: field.baseType), size: field.size)

        case (_, .string), (_, nil):
            append(rawInteger: field.baseType.invalidValue, size: field.size)
        }
    }

    private func clamp(_ value: Int64, to baseType: FITBaseType) -> UInt64 {
        switch baseType {
        case .sint8:
            return UInt64(UInt8(bitPattern: Int8(clamping: value)))
        case .sint16:
            return UInt64(UInt16(bitPattern: Int16(clamping: value)))
        case .sint32:
            return UInt64(UInt32(bitPattern: Int32(clamping: value)))
        default:
            let maxValue = Int64(
                baseType.invalidValue == 0 ? (1 << (baseType.size * 8)) - 1 : Int64(baseType.invalidValue) - 1)
            return UInt64(min(max(value, 0), maxValue))
        }
    }

    private mutating func append(rawInteger: UInt64, size: Int) {
        for index in 0..<size {
            body.append(UInt8((rawInteger >> (8 * UInt64(index))) & 0xFF))
        }
    }
}

extension Data {
    fileprivate mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    fileprivate mutating func append(littleEndian value: UInt32) {
        for index in 0..<4 {
            append(UInt8((value >> (8 * UInt32(index))) & 0xFF))
        }
    }
}
