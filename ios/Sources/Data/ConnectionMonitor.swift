// ConnectionMonitor — Observes GSPClient state and synthesizes connection status.

import Foundation
import Combine

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case authenticated
    case attached(sessionId: UInt32)
    case connectionLost(reason: String)
}

@MainActor
class ConnectionMonitor: ObservableObject {
    @Published var status: ConnectionStatus = .disconnected

    private let client: GSPClient
    private var cancellables = Set<AnyCancellable>()

    // Last-used connection parameters for reconnection
    private(set) var lastHost: String?
    private(set) var lastPort: UInt16?
    private(set) var lastAuthKey: String?

    init(client: GSPClient) {
        self.client = client
        observe()
    }

    private func observe() {
        // Combine multiple published properties into a single status
        Publishers.CombineLatest4(
            client.$connected,
            client.$authenticated,
            client.$attachedSessionId,
            client.$lastError
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] connected, authenticated, sessionId, error in
            guard let self else { return }

            if let sessionId {
                self.status = .attached(sessionId: sessionId)
            } else if let error, !connected, self.status != .disconnected {
                self.status = .connectionLost(reason: error)
            } else if authenticated {
                self.status = .authenticated
            } else if connected {
                self.status = .connected
            } else if self.lastHost != nil, case .attached = self.status {
                // Was attached, now disconnected — connection lost
                self.status = .connectionLost(reason: "Connection closed")
            } else {
                self.status = .disconnected
            }
        }
        .store(in: &cancellables)
    }

    func connect(host: String, port: UInt16, authKey: String = "") {
        lastHost = host
        lastPort = port
        lastAuthKey = authKey
        status = .connecting
        client.connect(host: host, port: port, authKey: authKey)
    }

    func reconnect() {
        guard let host = lastHost, let port = lastPort else { return }
        connect(host: host, port: port, authKey: lastAuthKey ?? "")
    }

    func disconnect() {
        client.disconnect()
        status = .disconnected
        lastHost = nil
        lastPort = nil
        lastAuthKey = nil
    }
}
