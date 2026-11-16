import Foundation

public struct TrustedDevice: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let signingPublicKey: Data
    public let sessionKey: Data
    public let pairedAt: Date

    public init(
        id: String,
        name: String,
        signingPublicKey: Data,
        sessionKey: Data,
        pairedAt: Date
    ) {
        self.id = id
        self.name = name
        self.signingPublicKey = signingPublicKey
        self.sessionKey = sessionKey
        self.pairedAt = pairedAt
    }
}

public protocol TrustedDeviceStore: Sendable {
    func all() throws -> [TrustedDevice]
    func device(forSigningKey key: Data) throws -> TrustedDevice?
    func add(_ device: TrustedDevice) throws
    func remove(id: String) throws
}

public final class InMemoryTrustedDeviceStore: TrustedDeviceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: TrustedDevice] = [:]

    public init() {}

    public func all() throws -> [TrustedDevice] {
        lock.withLock { Array(devices.values).sorted { $0.pairedAt < $1.pairedAt } }
    }

    public func device(forSigningKey key: Data) throws -> TrustedDevice? {
        lock.withLock { devices.values.first { $0.signingPublicKey == key } }
    }

    public func add(_ device: TrustedDevice) throws {
        lock.withLock { devices[device.id] = device }
    }

    public func remove(id: String) throws {
        lock.withLock { _ = devices.removeValue(forKey: id) }
    }
}
