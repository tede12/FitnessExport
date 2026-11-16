import Foundation

public enum SyncStream: Codable, Sendable, Hashable {
    case quantity(String)
    case category(String)
    case workouts
    case routes

    public var storageKey: String {
        switch self {
        case .quantity(let key): return "q:\(key)"
        case .category(let key): return "c:\(key)"
        case .workouts: return "workouts"
        case .routes: return "routes"
        }
    }

    public var title: String {
        switch self {
        case .quantity(let key), .category(let key):
            return HealthCatalog.metric(forKey: key)?.title ?? key
        case .workouts: return "Allenamenti"
        case .routes: return "Percorsi GPS"
        }
    }
}

public struct SyncStreamCursor: Codable, Sendable, Equatable {
    public let stream: SyncStream

    public let anchor: Data?

    public let since: Date?

    public init(stream: SyncStream, anchor: Data?, since: Date?) {
        self.stream = stream
        self.anchor = anchor
        self.since = since
    }
}

public struct SyncRequest: Codable, Sendable, Equatable {
    public let cursors: [SyncStreamCursor]

    public let maxBatchRecords: Int

    public let maxInFlightBatches: Int
    public let compression: PayloadCompression

    public init(
        cursors: [SyncStreamCursor],
        maxBatchRecords: Int = 10_000,
        maxInFlightBatches: Int = 4,
        compression: PayloadCompression = .lzfse
    ) {
        self.cursors = cursors
        self.maxBatchRecords = maxBatchRecords
        self.maxInFlightBatches = maxInFlightBatches
        self.compression = compression
    }
}

public enum BatchKind: String, Codable, Sendable {

    case upsert

    case delete
}

public struct BatchHeader: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let stream: SyncStream
    public let kind: BatchKind
    public let recordCount: Int
    public let payloadBytes: Int
    public let rawBytes: Int
    public let compression: PayloadCompression

    public let anchor: Data?

    public let isFinal: Bool

    public init(
        sequence: UInt64, stream: SyncStream, kind: BatchKind, recordCount: Int,
        payloadBytes: Int, rawBytes: Int, compression: PayloadCompression, anchor: Data?,
        isFinal: Bool
    ) {
        self.sequence = sequence
        self.stream = stream
        self.kind = kind
        self.recordCount = recordCount
        self.payloadBytes = payloadBytes
        self.rawBytes = rawBytes
        self.compression = compression
        self.anchor = anchor
        self.isFinal = isFinal
    }
}

public struct SyncCatalogReport: Codable, Sendable, Equatable {
    public let deviceName: String
    public let appVersion: String
    public let protocolVersion: Int

    public let unavailableMetricKeys: [String]

    public let profile: AthleteProfile?

    public init(
        deviceName: String, appVersion: String, protocolVersion: Int = SyncProtocolVersion.current,
        unavailableMetricKeys: [String], profile: AthleteProfile? = nil
    ) {
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.unavailableMetricKeys = unavailableMetricKeys
        self.profile = profile
    }
}

public struct SyncSummary: Codable, Sendable, Equatable {
    public let upserted: Int
    public let deleted: Int
    public let bytesSent: Int
    public let duration: TimeInterval

    public init(upserted: Int, deleted: Int, bytesSent: Int, duration: TimeInterval) {
        self.upserted = upserted
        self.deleted = deleted
        self.bytesSent = bytesSent
        self.duration = duration
    }
}

public struct SyncFailure: Codable, Sendable, Equatable, Error {
    public enum Code: String, Codable, Sendable {
        case unauthorized
        case protocolMismatch
        case healthUnavailable
        case healthDenied
        case storageFailed
        case payloadInvalid
        case cancelled
        case internalError
    }

    public let code: Code
    public let message: String

    public let stream: SyncStream?

    public init(code: Code, message: String, stream: SyncStream? = nil) {
        self.code = code
        self.message = message
        self.stream = stream
    }

    public var errorDescription: String? { message }
}

public enum SyncClientMessage: Codable, Sendable, Equatable {

    case pair(deviceName: String, signingPublicKey: Data, agreementPublicKey: Data)

    case authResponse(signature: Data)

    case ready(SyncCatalogReport)

    case batch(BatchHeader)

    case streamFailed(SyncFailure)

    case planMarks([PlanMark])
    case finished(SyncSummary)
    case failure(SyncFailure)
}

public enum SyncServerMessage: Codable, Sendable, Equatable {
    case authChallenge(nonce: Data)
    case paired(hostName: String, agreementPublicKey: Data)
    case authenticated(hostName: String)
    case syncRequest(SyncRequest)

    case batchAck(sequence: UInt64)

    case briefing(TrainingBriefing)
    case completed
    case failure(SyncFailure)
}
