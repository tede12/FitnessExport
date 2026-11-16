import Foundation

public enum SyncProtocolVersion {
    public static let current = 1
}

public struct PairingPayload: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let hostName: String
    public let host: String
    public let port: UInt16
    public let pairingKey: Data

    public init(
        protocolVersion: Int = SyncProtocolVersion.current,
        hostName: String,
        host: String,
        port: UInt16,
        pairingKey: Data
    ) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.host = host
        self.port = port
        self.pairingKey = pairingKey
    }

    public static func makePairingKey() -> Data {
        PairingCrypto.randomSecret()
    }

    public func qrString() -> String {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.scheme + json.base64URLEncodedString()
    }

    public init?(qrString: String) {
        guard qrString.hasPrefix(Self.scheme) else { return nil }
        let encoded = String(qrString.dropFirst(Self.scheme.count))
        guard
            let json = Data(base64URLEncoded: encoded),
            let payload = try? JSONDecoder().decode(PairingPayload.self, from: json)
        else { return nil }
        self = payload
    }

    private static let scheme = "fitnessexport://pair#"
}

extension Data {
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded string: String) {
        var padded =
            string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
