import Foundation
@preconcurrency import Network

public actor SyncListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.fitnessexport.sync.listener")

    private let connectionsStream: AsyncStream<SyncConnection>
    private let connectionsContinuation: AsyncStream<SyncConnection>.Continuation
    private var readyContinuation: CheckedContinuation<NWEndpoint.Port, Error>?
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var isCancelled = false

    public init(parameters: NWParameters, port: NWEndpoint.Port = .any) throws {
        listener = try NWListener(using: parameters, on: port)
        (connectionsStream, connectionsContinuation) = AsyncStream.makeStream(
            of: SyncConnection.self
        )
    }

    public var connections: AsyncStream<SyncConnection> { connectionsStream }

    @discardableResult
    public func start(timeout: Duration = .seconds(10)) async throws -> NWEndpoint.Port {
        guard !didStart else { return listener.port ?? .any }
        didStart = true

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut()
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            readyContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleNewConnection(connection) }
            }
            listener.start(queue: queue)
        }
    }

    private func cancelTimedOut() {
        guard let continuation = cancelContinuation else { return }
        cancelContinuation = nil
        continuation.resume()
    }

    private func timedOut() {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        listener.cancel()
        continuation.resume(
            throwing: SyncFailure(
                code: .internalError,
                message: "La porta non si è aperta entro il tempo previsto."
            )
        )
    }

    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        guard didStart else {
            listener.cancel()
            connectionsContinuation.finish()
            return
        }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.cancelTimedOut()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancelContinuation = continuation
            listener.cancel()
        }
        watchdog.cancel()
        connectionsContinuation.finish()
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            readyContinuation?.resume(returning: listener.port ?? .any)
            readyContinuation = nil
        case .failed(let error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            connectionsContinuation.finish()
        case .cancelled:
            cancelContinuation?.resume()
            cancelContinuation = nil
            connectionsContinuation.finish()
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) async {
        let sync = SyncConnection(connection: connection)

        try? await sync.start()
        connectionsContinuation.yield(sync)
    }
}
