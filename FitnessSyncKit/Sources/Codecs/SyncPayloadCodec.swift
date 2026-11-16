import Compression
import Foundation

public enum PayloadCompression: String, Codable, Sendable {
    case none
    case lzfse

    public func compress(_ data: Data) -> Data {
        switch self {
        case .none:
            return data
        case .lzfse:
            return (try? (data as NSData).compressed(using: .lzfse) as Data) ?? data
        }
    }

    public func decompress(_ data: Data, expectedByteCount: Int) throws -> Data {
        switch self {
        case .none:
            return data
        case .lzfse:
            return try (data as NSData).decompressed(using: .lzfse) as Data
        }
    }
}

public enum SyncPayloadCodec {
    static let quantityMagic: [UInt8] = Array("FXQ1".utf8)
    static let categoryMagic: [UInt8] = Array("FXK1".utf8)
    static let routeMagic: [UInt8] = Array("FXR1".utf8)

    public static func encodeQuantities(_ records: [QuantityRecord], sources: [SourceRecord]) -> Data {

        var writer = ByteWriter(reservingCapacity: records.count * 24 + 256)
        writer.writeBytes(quantityMagic)
        writeSourceTable(sources, into: &writer)
        writer.writeVarint(UInt64(records.count))
        ColumnarCodec.writeUUIDs(records.map(\.uuid), into: &writer)
        ColumnarCodec.writeTimestamps(records.map(\.start), into: &writer)

        ColumnarCodec.writeInts(
            records.map { Int(($0.end.timeIntervalSince($0.start) * 1_000).rounded()) },
            into: &writer
        )
        ColumnarCodec.writeDoubles(records.map(\.value), into: &writer)
        ColumnarCodec.writeInts(records.map(\.sourceIndex), into: &writer)
        return writer.data
    }

    public static func decodeQuantities(_ data: Data) throws -> (
        records: [QuantityRecord], sources: [SourceRecord]
    ) {
        var reader = ByteReader(data)
        try expect(magic: quantityMagic, in: &reader)
        let sources = try readSourceTable(from: &reader)
        let count = Int(try reader.readVarint())
        let uuids = try ColumnarCodec.readUUIDs(count: count, from: &reader)
        let starts = try ColumnarCodec.readTimestamps(count: count, from: &reader)
        let durations = try ColumnarCodec.readInts(count: count, from: &reader)
        let values = try ColumnarCodec.readDoubles(count: count, from: &reader)
        let sourceIndices = try ColumnarCodec.readInts(count: count, from: &reader)

        var records: [QuantityRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            records.append(
                QuantityRecord(
                    uuid: uuids[i],
                    start: starts[i],
                    end: starts[i].addingTimeInterval(Double(durations[i]) / 1_000),
                    value: values[i],
                    sourceIndex: sourceIndices[i]
                )
            )
        }
        return (records, sources)
    }

    public static func encodeCategories(_ records: [CategoryRecord], sources: [SourceRecord]) -> Data {
        var writer = ByteWriter(reservingCapacity: records.count * 24 + 256)
        writer.writeBytes(categoryMagic)
        writeSourceTable(sources, into: &writer)
        writer.writeVarint(UInt64(records.count))
        ColumnarCodec.writeUUIDs(records.map(\.uuid), into: &writer)
        ColumnarCodec.writeTimestamps(records.map(\.start), into: &writer)
        ColumnarCodec.writeInts(
            records.map { Int(($0.end.timeIntervalSince($0.start) * 1_000).rounded()) },
            into: &writer
        )
        ColumnarCodec.writeInts(records.map(\.value), into: &writer)
        ColumnarCodec.writeInts(records.map(\.sourceIndex), into: &writer)
        return writer.data
    }

    public static func decodeCategories(_ data: Data) throws -> (
        records: [CategoryRecord], sources: [SourceRecord]
    ) {
        var reader = ByteReader(data)
        try expect(magic: categoryMagic, in: &reader)
        let sources = try readSourceTable(from: &reader)
        let count = Int(try reader.readVarint())
        let uuids = try ColumnarCodec.readUUIDs(count: count, from: &reader)
        let starts = try ColumnarCodec.readTimestamps(count: count, from: &reader)
        let durations = try ColumnarCodec.readInts(count: count, from: &reader)
        let values = try ColumnarCodec.readInts(count: count, from: &reader)
        let sourceIndices = try ColumnarCodec.readInts(count: count, from: &reader)

        var records: [CategoryRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            records.append(
                CategoryRecord(
                    uuid: uuids[i],
                    start: starts[i],
                    end: starts[i].addingTimeInterval(Double(durations[i]) / 1_000),
                    value: values[i],
                    sourceIndex: sourceIndices[i]
                )
            )
        }
        return (records, sources)
    }

    public static func encodeRoutes(_ routes: [RouteRecord]) -> Data {
        let totalPoints = routes.reduce(0) { $0 + $1.points.count }
        var writer = ByteWriter(reservingCapacity: totalPoints * 40 + 64)
        writer.writeBytes(routeMagic)
        writer.writeVarint(UInt64(routes.count))
        for route in routes {
            ColumnarCodec.writeUUIDs([route.workoutUUID], into: &writer)
            writer.writeVarint(UInt64(route.points.count))
            ColumnarCodec.writeTimestamps(route.points.map(\.timestamp), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.latitude), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.longitude), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.altitude), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.horizontalAccuracy), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.verticalAccuracy), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.speed), into: &writer)
            ColumnarCodec.writeDoubles(route.points.map(\.course), into: &writer)
        }
        return writer.data
    }

    public static func decodeRoutes(_ data: Data) throws -> [RouteRecord] {
        var reader = ByteReader(data)
        try expect(magic: routeMagic, in: &reader)
        let routeCount = Int(try reader.readVarint())
        var routes: [RouteRecord] = []
        routes.reserveCapacity(routeCount)
        for _ in 0..<routeCount {
            let workoutUUID = try ColumnarCodec.readUUIDs(count: 1, from: &reader)[0]
            let count = Int(try reader.readVarint())
            let timestamps = try ColumnarCodec.readTimestamps(count: count, from: &reader)
            let latitudes = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let longitudes = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let altitudes = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let hAccuracy = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let vAccuracy = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let speeds = try ColumnarCodec.readDoubles(count: count, from: &reader)
            let courses = try ColumnarCodec.readDoubles(count: count, from: &reader)

            var points: [RoutePointRecord] = []
            points.reserveCapacity(count)
            for i in 0..<count {
                points.append(
                    RoutePointRecord(
                        timestamp: timestamps[i],
                        latitude: latitudes[i],
                        longitude: longitudes[i],
                        altitude: altitudes[i],
                        horizontalAccuracy: hAccuracy[i],
                        verticalAccuracy: vAccuracy[i],
                        speed: speeds[i],
                        course: courses[i]
                    )
                )
            }
            routes.append(RouteRecord(workoutUUID: workoutUUID, points: points))
        }
        return routes
    }

    public static func encodeWorkouts(_ workouts: [WorkoutRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(workouts)
    }

    public static func decodeWorkouts(_ data: Data) throws -> [WorkoutRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([WorkoutRecord].self, from: data)
    }

    public static func encodeDeletions(_ uuids: [UUID]) -> Data {
        var writer = ByteWriter(reservingCapacity: uuids.count * 16 + 8)
        writer.writeVarint(UInt64(uuids.count))
        ColumnarCodec.writeUUIDs(uuids, into: &writer)
        return writer.data
    }

    public static func decodeDeletions(_ data: Data) throws -> [UUID] {
        var reader = ByteReader(data)
        let count = Int(try reader.readVarint())
        return try ColumnarCodec.readUUIDs(count: count, from: &reader)
    }

    private static func writeSourceTable(_ sources: [SourceRecord], into writer: inout ByteWriter) {
        writer.writeVarint(UInt64(sources.count))
        for source in sources {
            writer.writeString(source.bundleID)
            writer.writeString(source.name)
        }
    }

    private static func readSourceTable(from reader: inout ByteReader) throws -> [SourceRecord] {
        let count = Int(try reader.readVarint())
        var sources: [SourceRecord] = []
        sources.reserveCapacity(count)
        for _ in 0..<count {
            sources.append(
                SourceRecord(bundleID: try reader.readString(), name: try reader.readString())
            )
        }
        return sources
    }

    private static func expect(magic: [UInt8], in reader: inout ByteReader) throws {
        let found = try reader.readBytes(magic.count)
        guard found == magic else {
            throw ColumnarError.malformed("magic inatteso")
        }
    }
}
