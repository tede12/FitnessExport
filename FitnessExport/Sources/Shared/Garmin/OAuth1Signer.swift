import CryptoKit
import Foundation

struct OAuth1Signer: Sendable {
    let consumerKey: String
    let consumerSecret: String
    var token: String?
    var tokenSecret: String?

    func authorizationHeader(
        method: String,
        url: URL,
        bodyParameters: [String: String] = [:],
        nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        timestamp: String = String(Int(Date().timeIntervalSince1970))
    ) -> String {
        var oauthParameters: [String: String] = [
            "oauth_consumer_key": consumerKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": timestamp,
            "oauth_version": "1.0",
        ]
        if let token {
            oauthParameters["oauth_token"] = token
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryParameters = (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        components.query = nil
        components.fragment = nil
        let baseURL = components.string!

        var allParameters: [(String, String)] = queryParameters
        for (key, value) in bodyParameters { allParameters.append((key, value)) }
        for (key, value) in oauthParameters { allParameters.append((key, value)) }

        let encodedPairs: [(String, String)] = allParameters.map { (Self.encode($0.0), Self.encode($0.1)) }
        let sortedPairs = encodedPairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let normalized = sortedPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        let baseString = [method.uppercased(), Self.encode(baseURL), Self.encode(normalized)].joined(separator: "&")
        let signingKey = "\(Self.encode(consumerSecret))&\(Self.encode(tokenSecret ?? ""))"
        let signature = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(baseString.utf8), using: SymmetricKey(data: Data(signingKey.utf8)))
        oauthParameters["oauth_signature"] = Data(signature).base64EncodedString()

        let header =
            oauthParameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\(Self.encode($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth \(header)"
    }

    static func encode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
