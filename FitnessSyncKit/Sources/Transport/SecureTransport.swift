import CryptoKit
import Foundation
@preconcurrency import Network

/// TLS-PSK requires TLS 1.2; both peers use the same identity and derived key.
public enum SecureTransport {

    public static let pskIdentityLabel = "org.fitnessexport.sync"

    public static let defaultPort: UInt16 = 7444

    public static func parameters(sessionKey: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let keyData = sessionKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(pskIdentityLabel.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            sec,
            keyData as __DispatchData,
            identityData as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            sec,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true

        tcp.connectionTimeout = 15

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false

        params.allowLocalEndpointReuse = true
        return params
    }
}
