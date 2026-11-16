import CryptoKit
import Foundation
@preconcurrency import Network
import XCTest

@testable import FitnessSyncKit

final class ListenerRebindTests: XCTestCase {

    func testRebindingTheSamePortImmediatelyAfterCancelling() async throws {
        let port = NWEndpoint.Port(rawValue: 7555)!
        let firstKey = SymmetricKey(data: PairingCrypto.randomSecret())
        let secondKey = SymmetricKey(data: PairingCrypto.randomSecret())

        let first = try SyncListener(
            parameters: SecureTransport.parameters(sessionKey: firstKey), port: port
        )
        _ = try await first.start()

        let client = SyncConnection(
            to: .hostPort(host: .ipv4(.loopback), port: port),
            parameters: SecureTransport.parameters(sessionKey: firstKey)
        )
        try await client.start()
        await client.cancel()

        await first.cancel()

        do {
            let second = try SyncListener(
                parameters: SecureTransport.parameters(sessionKey: secondKey), port: port
            )
            _ = try await second.start()
            await second.cancel()
        } catch {
            XCTFail("rebinding port 7555 failed: \(error)")
        }
    }

    func testTwoListenersOnTheSamePortAreRefused() async throws {
        let port = NWEndpoint.Port(rawValue: 7556)!
        let first = try SyncListener(
            parameters: SecureTransport.parameters(
                sessionKey: SymmetricKey(data: PairingCrypto.randomSecret())
            ),
            port: port
        )
        _ = try await first.start()
        defer { Task { await first.cancel() } }

        var secondFailed = false
        do {
            let second = try SyncListener(
                parameters: SecureTransport.parameters(
                    sessionKey: SymmetricKey(data: PairingCrypto.randomSecret())
                ),
                port: port
            )
            _ = try await second.start()
            await second.cancel()
        } catch {
            secondFailed = true
        }
        XCTAssertTrue(secondFailed, "a second listener on a busy port must fail loudly")
    }
}
