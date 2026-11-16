import Foundation
@preconcurrency import Network

public actor SyncConnection {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.fitnessexport.sync.connection")
    private var reader = FrameReader()

    private let controlStream: AsyncThrowingStream<Data, Error>
    private let controlContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let payloadStream: AsyncThrowingStream<Data, Error>
    private let payloadContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var didStart = false
    private var isCancelled = false

    public init(connection: NWConnection) {
        self.connection = connection
        (controlStream, controlContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (payloadStream, payloadContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    public init(to endpoint: NWEndpoint, parameters: NWParameters) {
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    public var control: AsyncThrowingStream<Data, Error> { controlStream }

    public var payloads: AsyncThrowingStream<Data, Error> { payloadStream }

    public var isLive: Bool { !isCancelled }

    public func start() async throws {
        guard !didStart else { return }
        didStart = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            startContinuation = cont
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleState(state) }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: frame,
                completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            )
        }
    }

    public func sendMessage(_ message: some Encodable) async throws {
        try await send(MessageFraming.encode(message))
    }

    public func sendPayload(_ payload: Data) async throws {
        try await send(MessageFraming.encodePayload(payload))
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        connection.cancel()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startContinuation?.resume()
            startContinuation = nil
            receiveNext()
        case .failed(let error):
            isCancelled = true
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            controlContinuation.finish(throwing: error)
            payloadContinuation.finish(throwing: error)
        case .waiting(let error):

            isCancelled = true
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            controlContinuation.finish(throwing: error)
            payloadContinuation.finish(throwing: error)
            connection.cancel()
        case .cancelled:
            isCancelled = true
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
            controlContinuation.finish()
            payloadContinuation.finish()
        default:
            break
        }
    }

    private func receiveNext() {

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            controlContinuation.finish(throwing: error)
            payloadContinuation.finish(throwing: error)
            return
        }
        if let data, !data.isEmpty {
            reader.append(data)
            do {
                while let frame = try reader.next() {
                    switch frame.kind {
                    case .control: controlContinuation.yield(frame.payload)
                    case .payload: payloadContinuation.yield(frame.payload)
                    }
                }
            } catch {
                controlContinuation.finish(throwing: error)
                payloadContinuation.finish(throwing: error)
                cancel()
                return
            }
        }
        if isComplete {
            controlContinuation.finish()
            payloadContinuation.finish()
            return
        }
        receiveNext()
    }
}
