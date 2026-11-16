import Foundation

public enum FrameKind: UInt8, Sendable {
    case control = 0
    case payload = 1
}

public enum MessageFraming {
    public static let headerSize = 5

    public static let maxPayloadSize = 32 * 1024 * 1024

    public enum FramingError: Error, Equatable {
        case payloadTooLarge(Int)
        case unknownKind(UInt8)
    }

    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try frame(kind: .control, payload: JSONEncoder().encode(message))
    }

    public static func encodePayload(_ payload: Data) throws -> Data {
        try frame(kind: .payload, payload: payload)
    }

    static func frame(kind: FrameKind, payload: Data) throws -> Data {
        guard payload.count <= maxPayloadSize else {
            throw FramingError.payloadTooLarge(payload.count)
        }
        var data = Data(capacity: headerSize + payload.count)
        data.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func decode<Message: Decodable>(
        _ type: Message.Type,
        from payload: Data
    ) throws -> Message {
        try JSONDecoder().decode(type, from: payload)
    }
}

public struct FrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> (kind: FrameKind, payload: Data)? {
        guard buffer.count >= MessageFraming.headerSize else { return nil }

        let start = buffer.startIndex
        let kindByte = buffer[start]
        guard let kind = FrameKind(rawValue: kindByte) else {
            throw MessageFraming.FramingError.unknownKind(kindByte)
        }

        let length = buffer[(start + 1)..<(start + 5)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        let payloadLength = Int(length)
        guard payloadLength <= MessageFraming.maxPayloadSize else {
            throw MessageFraming.FramingError.payloadTooLarge(payloadLength)
        }
        guard buffer.count >= MessageFraming.headerSize + payloadLength else { return nil }

        let payloadStart = buffer.index(start, offsetBy: MessageFraming.headerSize)
        let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLength)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(start..<payloadEnd)
        return (kind, payload)
    }
}
