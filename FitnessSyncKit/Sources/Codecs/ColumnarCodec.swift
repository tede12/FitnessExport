import Foundation

public enum ColumnarError: Error, Equatable {
    case truncated
    case malformed(String)
    case unsupportedVersion(UInt8)
}

public struct ByteWriter {
    public private(set) var bytes: [UInt8] = []

    public init(reservingCapacity capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    public var data: Data { Data(bytes) }

    public mutating func writeByte(_ byte: UInt8) {
        bytes.append(byte)
    }

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    public mutating func writeZigzag(_ value: Int64) {
        writeVarint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    public mutating func writeDouble(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
    }

    public mutating func writeBytes(_ raw: [UInt8]) {
        bytes.append(contentsOf: raw)
    }

    public mutating func writeString(_ string: String) {
        let utf8 = Array(string.utf8)
        writeVarint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

public struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int

    public init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    public var isAtEnd: Bool { offset >= bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw ColumnarError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw ColumnarError.truncated }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else { throw ColumnarError.malformed("varint troppo lungo") }
        }
        return result
    }

    public mutating func readZigzag() throws -> Int64 {
        let raw = try readVarint()
        return Int64(bitPattern: (raw >> 1)) ^ -(Int64(bitPattern: raw) & 1)
    }

    public mutating func readDouble() throws -> Double {
        guard offset + 8 <= bytes.count else { throw ColumnarError.truncated }
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits |= UInt64(bytes[offset + i]) << (8 * UInt64(i))
        }
        offset += 8
        return Double(bitPattern: UInt64(littleEndian: bits))
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw ColumnarError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    public mutating func readString() throws -> String {
        let length = Int(try readVarint())
        let raw = try readBytes(length)
        return String(decoding: raw, as: UTF8.self)
    }
}

/// Floating-point scaling is used only when every value round-trips exactly.
public enum ColumnarCodec {

    static let candidateScales: [Double] = [
        1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000,
    ]

    public static func writeTimestamps(_ dates: [Date], into writer: inout ByteWriter) {
        var previous: Int64 = 0
        for (index, date) in dates.enumerated() {
            let millis = Int64((date.timeIntervalSince1970 * 1_000).rounded())
            writer.writeZigzag(index == 0 ? millis : millis - previous)
            previous = millis
        }
    }

    public static func readTimestamps(count: Int, from reader: inout ByteReader) throws -> [Date] {
        var dates: [Date] = []
        dates.reserveCapacity(count)
        var previous: Int64 = 0
        for index in 0..<count {
            let delta = try reader.readZigzag()
            let millis = index == 0 ? delta : previous + delta
            previous = millis
            dates.append(Date(timeIntervalSince1970: Double(millis) / 1_000))
        }
        return dates
    }

    public static func writeDoubles(_ values: [Double], into writer: inout ByteWriter) {
        guard let scale = exactScale(for: values) else {
            writer.writeByte(0)
            for value in values { writer.writeDouble(value) }
            return
        }
        writer.writeByte(1)
        writer.writeVarint(UInt64(scale))
        var previous: Int64 = 0
        for (index, value) in values.enumerated() {
            let scaled = Int64((value * Double(scale)).rounded())
            writer.writeZigzag(index == 0 ? scaled : scaled - previous)
            previous = scaled
        }
    }

    public static func readDoubles(count: Int, from reader: inout ByteReader) throws -> [Double] {
        let mode = try reader.readByte()
        var values: [Double] = []
        values.reserveCapacity(count)
        switch mode {
        case 0:
            for _ in 0..<count { values.append(try reader.readDouble()) }
        case 1:
            let scale = Double(try reader.readVarint())
            guard scale > 0 else { throw ColumnarError.malformed("scala nulla") }
            var previous: Int64 = 0
            for index in 0..<count {
                let delta = try reader.readZigzag()
                let scaled = index == 0 ? delta : previous + delta
                previous = scaled
                values.append(Double(scaled) / scale)
            }
        default:
            throw ColumnarError.malformed("modalità double sconosciuta: \(mode)")
        }
        return values
    }

    static func exactScale(for values: [Double]) -> UInt64? {
        guard !values.isEmpty else { return 1 }
        for scale in candidateScales {
            var ok = true
            for value in values {
                guard value.isFinite else { return nil }
                let scaled = (value * scale).rounded()
                guard scaled.magnitude < 9.0e18, scaled / scale == value else {
                    ok = false
                    break
                }
            }
            if ok { return UInt64(scale) }
        }
        return nil
    }

    public static func writeInts(_ values: [Int], into writer: inout ByteWriter) {
        for value in values { writer.writeZigzag(Int64(value)) }
    }

    public static func readInts(count: Int, from reader: inout ByteReader) throws -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(Int(try reader.readZigzag())) }
        return values
    }

    public static func writeUUIDs(_ uuids: [UUID], into writer: inout ByteWriter) {
        for uuid in uuids {
            let u = uuid.uuid
            writer.writeBytes([
                u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
            ])
        }
    }

    public static func readUUIDs(count: Int, from reader: inout ByteReader) throws -> [UUID] {
        var uuids: [UUID] = []
        uuids.reserveCapacity(count)
        for _ in 0..<count {
            let b = try reader.readBytes(16)
            uuids.append(
                UUID(
                    uuid: (
                        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
                    )
                )
            )
        }
        return uuids
    }
}
